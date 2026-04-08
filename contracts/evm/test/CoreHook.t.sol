// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {TransientSlots} from "../src/libraries/TransientSlots.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PositionId, Position, PositionLibrary} from "../src/types/Position.sol";
import {RFSCheckpoint} from "../src/types/Checkpoint.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MarketTestBase} from "./base/MarketTestBase.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";

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
        // Add-liquidity caller legs are negative deltas.
        BalanceDelta delta = toBalanceDelta(int128(-10), int128(-20));
        BalanceDelta feeAdj = toBalanceDelta(int128(3), int128(5));

        vts.setReturn(feeAdj, false);

        (bytes4 sel, BalanceDelta returnedFeeAdj) =
            hook.exposed_afterAddLiquidity(address(this), key, _dummyParams(), delta, BalanceDelta.wrap(0), "");
        assertEq(sel, hook.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(returnedFeeAdj), BalanceDelta.unwrap(feeAdj));

        assertEq(spy.calls(), 1, "spy should be called once");
    }

    function test_afterRemoveLiquidity_doesNotForward_whenMM() public {
        vts.setReturn(toBalanceDelta(int128(1), int128(1)), true);

        hook.exposed_afterRemoveLiquidity(
            address(this), key, _dummyRemoveParams(), toBalanceDelta(int128(7), int128(9)), BalanceDelta.wrap(0), ""
        );

        assertEq(spy.calls(), 0, "spy should not be called for MM operations");
    }

    function test_afterRemoveLiquidity_doesNotForward_whenNotMM() public {
        BalanceDelta delta = toBalanceDelta(int128(7), int128(9));
        BalanceDelta feeAdj = toBalanceDelta(int128(2), int128(4));

        vts.setReturn(feeAdj, false);

        (bytes4 sel, BalanceDelta returnedFeeAdj) =
            hook.exposed_afterRemoveLiquidity(address(this), key, _dummyRemoveParams(), delta, BalanceDelta.wrap(0), "");
        assertEq(sel, hook.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(returnedFeeAdj), BalanceDelta.unwrap(feeAdj));

        assertEq(spy.calls(), 0, "spy must not be called on remove-liquidity");
    }

    function test_beforeRemoveLiquidity_settlesGrowths_evenWhenPaused() public {
        ModifyLiquidityParams memory params = _dummyParams();
        PositionId expectedId = PositionLibrary.generateId(address(this), params);
        vts.setPaused(true);

        bytes4 sel = hook.exposed_beforeRemoveLiquidity(address(this), key, params, "");

        assertEq(sel, hook.beforeRemoveLiquidity.selector);
        assertEq(PositionId.unwrap(vts.lastSettledPositionId()), PositionId.unwrap(expectedId));
        assertEq(vts.settlePositionGrowthsCalls(), 1, "growth settlement should still run while paused");
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
    // Mutant: CoreActionFlag.isDirectCoreAction(proxyHook) forced true in CoreHook._afterSwap
    // ------------------------------------------------------------

    function test_afterSwap_doesNotNotifyProxyHook_whenNoCoreActionFlagIsSet() public {
        // Simulate proxy swap in progress: direct-swap detection must be false, so no notification.
        spy.setNoCoreActionFlag(true);

        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: 0});
        hook.exposed_afterSwap(address(this), key, sp, toBalanceDelta(int128(-1), int128(1)), bytes(""));

        assertEq(spy.swapCalls(), 0, "should not notify proxy hook during proxy-initiated swaps");
    }

    function test_afterSwap_clearsTransientSwapSnapshotSlots() public {
        // Ensure CoreHook clears transient scratch slots after consuming them to avoid same-tx ghost state.
        uint160 sqrtPBefore = 123;
        uint128 liqBefore = 456;
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: 0});

        (uint256 sqrtAfter, uint256 liqAfter) = hook.exposed_afterSwap_withPresetSnapshot(
            key, sp, toBalanceDelta(int128(-1), int128(1)), sqrtPBefore, liqBefore, bytes("")
        );

        assertEq(vts.lastSqrtPBefore(), sqrtPBefore, "VTS should receive sqrtPBefore");
        assertEq(vts.lastLiqBefore(), liqBefore, "VTS should receive liqBefore");
        assertEq(sqrtAfter, 0, "SQRTP_BEFORE_SLOT should be cleared");
        assertEq(liqAfter, 0, "LIQ_BEFORE_SLOT should be cleared");
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    function _dummyParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1), salt: bytes32(0)});
    }

    function _dummyRemoveParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(1), salt: bytes32(0)});
    }
}

// ------------------------------------------------------------
// Harness & lightweight mocks/spies
// ------------------------------------------------------------

contract CoreHookHarness is CoreHook {
    using TransientSlot for *;

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

    function exposed_beforeRemoveLiquidity(
        address sender,
        PoolKey calldata k,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return _beforeRemoveLiquidity(sender, k, params, hookData);
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

    function exposed_afterSwap_withPresetSnapshot(
        PoolKey calldata k,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore,
        bytes calldata hookData
    ) external returns (uint256 sqrtAfter, uint256 liqAfter) {
        // Pre-seed transient slots to emulate the beforeSwap->afterSwap same-tx lifecycle.
        TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(uint256(sqrtPBefore));
        TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(uint256(liqBefore));

        _afterSwap(address(this), k, params, delta, hookData);

        sqrtAfter = TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tload();
        liqAfter = TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload();
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

    function sequenceDirectSwap(PoolKey calldata key, address lccTokenIn) external {
        address hook = _proxyToHook[PoolId.unwrap(key.toId())];
        if (hook != address(0)) {
            ProxyHookSpy(hook).handleSwap(lccTokenIn);
        }
    }

    function sequenceDirectAddLiquidity(PoolKey calldata key) external {
        address hook = _proxyToHook[PoolId.unwrap(key.toId())];
        if (hook != address(0)) {
            ProxyHookSpy(hook).handleAddLiquidity();
        }
    }
}

contract ProxyHookSpy {
    uint256 internal _calls;

    function handleAddLiquidity() external {
        _calls++;
    }

    // ---- direct swap spy + exttload hook for CoreActionFlag.isDirectCoreAction(proxyHook) ----

    uint256 internal _swapCalls;
    address internal _lastSwapLcc;
    bytes32 internal _proxySwapFlag;

    function setNoCoreActionFlag(bool on) external {
        _proxySwapFlag = on ? bytes32(uint256(1)) : bytes32(0);
    }

    function exttload(bytes32) external view returns (bytes32) {
        // CoreHook checks direct swaps via CoreActionFlag.isDirectCoreAction(proxyHook),
        // which reads PROXY_SWAP_FLAG_SLOT from the proxy hook via IExttload.exttload.
        return _proxySwapFlag;
    }

    function handleSwap(address lccTokenIn) external {
        _swapCalls++;
        _lastSwapLcc = lccTokenIn;
    }

    function calls() external view returns (uint256) {
        return _calls;
    }

    function swapCalls() external view returns (uint256) {
        return _swapCalls;
    }

    function lastSwapLcc() external view returns (address) {
        return _lastSwapLcc;
    }
}

contract MockVTSOrchestrator {
    BalanceDelta internal _feeAdj;
    bool internal _isMM;
    bool internal _paused;

    uint160 internal _lastSqrtPBefore;
    uint128 internal _lastLiqBefore;
    PositionId internal _lastSettledPositionId;
    uint256 internal _settlePositionGrowthsCalls;

    function setReturn(BalanceDelta feeAdj, bool isMMPosition) external {
        _feeAdj = feeAdj;
        _isMM = isMMPosition;
    }

    function setPaused(bool paused) external {
        _paused = paused;
    }

    function processPosition(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition) {
        return _positionReturn();
    }

    function _positionReturn()
        private
        view
        returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
    {
        pos = Position({
            owner: address(0),
            poolId: PoolId.wrap(bytes32(0)),
            commitId: 0,
            tickLower: 0,
            tickUpper: 0,
            liquidity: 0,
            isActive: false,
            salt: bytes32(0),
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
        id = PositionId.wrap(bytes32(0));
        feeAdj = _feeAdj;
        isMMPosition = _isMM;
    }

    function afterCoreSwap(PoolKey calldata, SwapParams calldata, BalanceDelta, uint160 sqrtPBefore, uint128 liqBefore)
        external
    {
        _lastSqrtPBefore = sqrtPBefore;
        _lastLiqBefore = liqBefore;
    }

    function settlePositionGrowths(PositionId positionId) external {
        _lastSettledPositionId = positionId;
        _settlePositionGrowthsCalls++;
    }

    function lastSqrtPBefore() external view returns (uint160) {
        return _lastSqrtPBefore;
    }

    function lastLiqBefore() external view returns (uint128) {
        return _lastLiqBefore;
    }

    function lastSettledPositionId() external view returns (PositionId) {
        return _lastSettledPositionId;
    }

    function settlePositionGrowthsCalls() external view returns (uint256) {
        return _settlePositionGrowthsCalls;
    }

    function isPoolPaused(PoolId) external pure returns (bool) {
        return false;
    }

    function isPaused() external pure returns (bool) {
        return false;
    }

    function isPoolOrGlobalPaused(PoolId) external view returns (bool) {
        return _paused;
    }
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

/// @dev Executes LiquidityHub.unwrap inside PoolManager.unlock.
contract UnwrapInUnlockRunner {
    IPoolManager internal immutable pm;
    address internal immutable hub;
    address internal lcc;
    uint256 internal amt;

    constructor(IPoolManager pm_, address hub_) {
        pm = pm_;
        hub = hub_;
    }

    function run(address lcc_, uint256 amt_) external {
        lcc = lcc_;
        amt = amt_;
        pm.unlock(bytes(""));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        LiquidityHub(payable(hub)).unwrap(lcc, amt);
        return bytes("");
    }
}

/// @dev Test-only PositionManager that can unwrap LCC inside the same PoolManager.unlock.
///      This models a true single-transaction action pipeline:
///      DECREASE -> TAKE_PAIR -> (unwrap LCC) -> SWEEP underlying.
contract FietPositionManager is PositionManager {
    uint256 internal constant FIET_UNWRAP_LCC = 0x80;

    address internal immutable _liquidityHub;

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        address liquidityHub_
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        _liquidityHub = liquidityHub_;
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action == FIET_UNWRAP_LCC) {
            (address lcc, uint256 amount) = abi.decode(params, (address, uint256));
            // Default: unwrap the full market-derived balance held by this contract.
            uint256 toUnwrap = amount;
            if (toUnwrap == 0) {
                (, uint256 marketBal) = ILCC(lcc).balancesOf(address(this));
                toUnwrap = marketBal;
            }
            if (toUnwrap > 0) {
                LiquidityHub(payable(_liquidityHub)).unwrap(lcc, toUnwrap);
            }
            return;
        }
        super._handleAction(action, params);
    }
}

/// @dev Multicaller that composes (in a single EOA transaction):
///      (1) PosM unlock: DECREASE + TAKE_PAIR (LCC paid to this multicaller)
///      (2) PoolManager unlock: LiquidityHub.unwrapTo (underlying paid to end recipient)
///      (3) PosM call: SWEEP any residual token balances to end recipient
contract ThreeStepDecreaseUnwrapSweepMulticaller {
    IPoolManager internal immutable pm;
    address internal immutable hub;
    address internal immutable posm;

    address internal lcc0;
    address internal lcc1;
    address internal to;

    constructor(IPoolManager pm_, address hub_, address posm_) {
        pm = pm_;
        hub = hub_;
        posm = posm_;
    }

    function multicall(bytes[] calldata data) external {
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            ret;
            require(ok, "ThreeStepDecreaseUnwrapSweepMulticaller: call failed");
        }
    }

    function step1_decreaseAndTakePairToSelf(
        uint256 tokenId,
        uint256 liquidity,
        Currency coreCurrency0,
        Currency coreCurrency1
    ) external {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, type(uint128).min, type(uint128).min, bytes(""));
        // TAKE_PAIR recipient = ActionConstants.MSG_SENDER => maps to PosM locker (this multicaller).
        params[1] = abi.encode(coreCurrency0, coreCurrency1, ActionConstants.MSG_SENDER);
        IPositionManager(posm).modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
    }

    function step2_unwrapTo_withOwnUnlock(address lcc0_, address lcc1_, address to_) external {
        lcc0 = lcc0_;
        lcc1 = lcc1_;
        to = to_;
        pm.unlock(bytes(""));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        // Unwrap all market-derived LCC held by this contract to the provided recipient.
        if (lcc0 != address(0)) {
            (, uint256 m0) = ILCC(lcc0).balancesOf(address(this));
            if (m0 > 0) LiquidityHub(payable(hub)).unwrapTo(lcc0, to, m0);
        }
        if (lcc1 != address(0)) {
            (, uint256 m1) = ILCC(lcc1).balancesOf(address(this));
            if (m1 > 0) LiquidityHub(payable(hub)).unwrapTo(lcc1, to, m1);
        }
        return bytes("");
    }

    function step3_sweepPosmTo(Currency underlying0, Currency underlying1, address to_) external {
        bytes memory actions = abi.encodePacked(uint8(Actions.SWEEP), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(underlying0, to_);
        params[1] = abi.encode(underlying1, to_);
        PositionManager(payable(posm)).modifyLiquiditiesWithoutUnlock(actions, params);
    }
}

/// @dev Executes a single-tx: DECREASE -> unwrap -> sweep.
///      This models the intended UX flow where a periphery/multicall wrapper composes:
///      - Decrease a DirectLP position (receive LCCs),
///      - Unwrap the received (market-derived) LCC into underlying (requires PoolManager.unlock),
///      - Sweep underlying to the end recipient.
contract DecreaseUnwrapSweepRunner {
    IPoolManager internal immutable pm;
    address internal immutable hub;
    address internal immutable posm;

    address internal lcc0;
    address internal lcc1;
    uint256 internal amt0;
    uint256 internal amt1;

    address internal u0;
    address internal u1;

    constructor(IPoolManager pm_, address hub_, address posm_) {
        pm = pm_;
        hub = hub_;
        posm = posm_;
    }

    function executeDecreaseUnwrapSweep(
        uint256 tokenId,
        uint256 liquidity,
        Currency coreCurrency0,
        Currency coreCurrency1,
        address underlying0,
        address underlying1,
        address recipient
    ) external {
        // 1) DECREASE + TAKE_PAIR to this contract (receive LCCs).
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, type(uint128).min, type(uint128).min, bytes(""));
        params[1] = abi.encode(coreCurrency0, coreCurrency1, address(this));

        IPositionManager(posm).modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);

        // Snapshot received LCC balances to unwrap (market-derived for PoolManager->EOA paths).
        address l0 = Currency.unwrap(coreCurrency0);
        address l1 = Currency.unwrap(coreCurrency1);
        (uint256 w0, uint256 m0) = ILCC(l0).balancesOf(address(this));
        (uint256 w1, uint256 m1) = ILCC(l1).balancesOf(address(this));

        // We expect DirectLP remove to credit as market-derived (wrapped must remain 0).
        require(w0 == 0 && w1 == 0, "DecreaseUnwrapSweepRunner: expected wrapped=0");
        require(m0 > 0 || m1 > 0, "DecreaseUnwrapSweepRunner: expected some LCC to unwrap");

        lcc0 = l0;
        lcc1 = l1;
        amt0 = m0;
        amt1 = m1;
        u0 = underlying0;
        u1 = underlying1;

        // 2) Unwrap within PoolManager.unlock (required for burn/take paths).
        pm.unlock(bytes(""));

        // 3) Sweep underlying out to the final recipient.
        if (u0 != address(0)) {
            uint256 bal0 = IERC20Minimal(u0).balanceOf(address(this));
            if (bal0 > 0) IERC20Minimal(u0).transfer(recipient, bal0);
        }
        if (u1 != address(0)) {
            uint256 bal1 = IERC20Minimal(u1).balanceOf(address(this));
            if (bal1 > 0) IERC20Minimal(u1).transfer(recipient, bal1);
        }
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (amt0 > 0) LiquidityHub(payable(hub)).unwrap(lcc0, amt0);
        if (amt1 > 0) LiquidityHub(payable(hub)).unwrap(lcc1, amt1);
        return bytes("");
    }
}

/// @dev Regression test for DirectLP remove-liquidity bucketing.
///      This reproduces the issue described in the DirectLP testing note:
///      - Remove-liquidity returns LCC from PoolManager (BUCKET-EXEMPT), so credits as market-derived
///      - Unwrap then sources underlying via market liquidity (MarketFactory -> MarketVault -> LiquidityHub), not via eager moves on remove
contract CoreHookDirectLPRemoveBucketingTest is MarketTestBase {
    address internal lp;

    struct DecreaseUnwrapSweepState {
        address lcc0;
        address lcc1;
        address ua0;
        address ua1;
        uint256 tokenId;
        uint256 liq;
        address runner;
        uint256 lpUa0Before;
        uint256 lpUa1Before;
        uint256 factoryUa0Before;
        uint256 factoryUa1Before;
    }

    struct ThreeCallMulticallState {
        address lcc0;
        address lcc1;
        address ua0;
        address ua1;
        uint256 tokenId;
        uint256 liq;
        address mc;
        uint256 lpUa0Before;
        uint256 lpUa1Before;
        uint256 factoryUa0Before;
        uint256 factoryUa1Before;
    }

    function _scanUnderlyingTransfers(Vm.Log[] memory entries, address underlying)
        internal
        view
        returns (bool sawPmToHub, bool sawPmToFactory)
    {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory e = entries[i];
            if (e.emitter != underlying) continue;
            if (e.topics.length == 0 || e.topics[0] != transferTopic) continue;

            address from = address(uint160(uint256(e.topics[1])));
            address to = address(uint160(uint256(e.topics[2])));
            if (from == address(manager) && to == address(liquidityHub)) sawPmToHub = true;
            if (from == address(manager) && to == marketFactory) sawPmToFactory = true;
        }
    }

    function _sumLccBuckets(address lcc, address who) internal view returns (uint256) {
        (uint256 w, uint256 m) = ILCC(lcc).balancesOf(who);
        return w + m;
    }

    function setUp() public {
        // Keep this light; we only need a functioning market and a small amount of liquidity.
        initialLiquidity = 10e18;
        _setupMarket();
        lp = makeAddr("direct_lp");
    }

    function test_directLP_removeLiquidity_creditsReturnedLCCAsMarketDerived_wrappedStaysFlat() public {
        LiquidityCommitmentCertificate lcc0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        LiquidityCommitmentCertificate lcc1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1)));

        // Fund LP with underlying and wrap to LCC so they can use Uni v4 PositionManager.
        uint256 wrapAmt = 5e18;
        {
            address ua0 = lcc0.underlying();
            address ua1 = lcc1.underlying();

            // For this test we assume ERC20 underlyings (native-backed markets have separate concerns).
            require(ua0 != address(0) && ua1 != address(0), "CoreHookDirectLPRemoveBucketingTest: native underlying");

            IERC20Minimal(ua0).transfer(lp, wrapAmt);
            IERC20Minimal(ua1).transfer(lp, wrapAmt);

            vm.startPrank(lp);
            IERC20Minimal(ua0).approve(liquidityHub, wrapAmt);
            LiquidityHub(liquidityHub).wrap(address(lcc0), wrapAmt);
            IERC20Minimal(ua1).approve(liquidityHub, wrapAmt);
            LiquidityHub(liquidityHub).wrap(address(lcc1), wrapAmt);

            // Permit2 approvals so PositionManager can settle the pair.
            IERC20Minimal(address(lcc0)).approve(address(permit2), type(uint256).max);
            IERC20Minimal(address(lcc1)).approve(address(permit2), type(uint256).max);
            permit2.approve(address(lcc0), address(uniPositionManager), type(uint160).max, type(uint48).max);
            permit2.approve(address(lcc1), address(uniPositionManager), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }

        // 1) Mint a DirectLP position via Uni PositionManager.
        uint256 tokenId = uniPositionManager.nextTokenId();
        uint256 liq = 1e12;
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(
                corePoolKey, int24(-60), int24(60), liq, type(uint128).max, type(uint128).max, lp, ZERO_BYTES
            );
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);

            vm.prank(lp);
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }

        // 2) Snapshot LP bucket balances after mint (before remove).
        (uint256 w0Before, uint256 m0Before) = ILCC(address(lcc0)).balancesOf(lp);
        (uint256 w1Before, uint256 m1Before) = ILCC(address(lcc1)).balancesOf(lp);

        // 3) Remove liquidity and TAKE_PAIR to LP.
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(tokenId, liq, type(uint128).min, type(uint128).min, ZERO_BYTES);
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, lp);

            vm.prank(lp);
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }

        // 4) Assert returned LCC is bucketed as MARKET-DERIVED, with WRAPPED unchanged.
        //
        // Rationale: the remove-liquidity path increases market-derived balances while wrapped stays flat.
        (uint256 w0After, uint256 m0After) = ILCC(address(lcc0)).balancesOf(lp);
        (uint256 w1After, uint256 m1After) = ILCC(address(lcc1)).balancesOf(lp);

        assertEq(w0After, w0Before, "expected LCC0 wrapped balance NOT to increase on remove");
        assertGt(m0After, m0Before, "expected LCC0 market-derived balance to increase on remove");

        assertEq(w1After, w1Before, "expected LCC1 wrapped balance NOT to increase on remove");
        assertGt(m1After, m1Before, "expected LCC1 market-derived balance to increase on remove");
    }

    function test_unwrap_marketDerived_withinUnlock_bubblesUnderlyingIntoLiquidityHub_notMarketFactory() public {
        LiquidityCommitmentCertificate lcc0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        address underlying0 = lcc0.underlying();
        require(underlying0 != address(0), "CoreHookDirectLPRemoveBucketingTest: native underlying");

        uint256 amount = 1e9;
        UnwrapInUnlockRunner runner = new UnwrapInUnlockRunner(IPoolManager(address(manager)), liquidityHub);

        // Manufacture market-derived LCC for this contract via protocol (proxyHook) -> non-protocol transfer.
        IERC20Minimal(underlying0).transfer(address(proxyHook), amount);
        vm.startPrank(address(proxyHook));
        IERC20Minimal(underlying0).approve(liquidityHub, amount);
        LiquidityHub(payable(liquidityHub)).wrap(address(lcc0), amount);
        IERC20Minimal(address(lcc0)).transfer(address(runner), amount);
        vm.stopPrank();

        (uint256 wrappedBal, uint256 marketBal) = ILCC(address(lcc0)).balancesOf(address(runner));
        assertEq(wrappedBal, 0, "precondition: holder should have wrapped=0");
        assertEq(marketBal, amount, "precondition: holder should have market-derived balance");

        uint256 holderUnderlyingBefore = IERC20Minimal(underlying0).balanceOf(address(runner));
        uint256 factoryUnderlyingBefore = IERC20Minimal(underlying0).balanceOf(marketFactory);

        // Unwrap must be executed within PoolManager.unlock to avoid ManagerLocked() on burn/take.
        vm.recordLogs();
        runner.run(address(lcc0), amount);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Hard assertions: underlying must transfer from PoolManager -> LiquidityHub, and must NOT transfer into MarketFactory.
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bool sawPmToHub = false;
        bool sawPmToFactory = false;
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory e = entries[i];
            if (e.emitter != underlying0) continue;
            if (e.topics.length == 0 || e.topics[0] != transferTopic) continue;

            address from = address(uint160(uint256(e.topics[1])));
            address to = address(uint160(uint256(e.topics[2])));
            if (from == address(manager) && to == address(liquidityHub)) sawPmToHub = true;
            if (from == address(manager) && to == marketFactory) sawPmToFactory = true;
        }

        assertTrue(sawPmToHub, "expected underlying to transfer PoolManager -> LiquidityHub during unwrap");
        assertFalse(sawPmToFactory, "underlying must not bubble into MarketFactory during unwrap");

        assertEq(IERC20Minimal(underlying0).balanceOf(address(runner)), holderUnderlyingBefore + amount);
        assertEq(IERC20Minimal(underlying0).balanceOf(marketFactory), factoryUnderlyingBefore);
    }

    function test_corePoolSwap_thenUnwrap_marketDerived_bubblesUnderlyingIntoLiquidityHub_notMarketFactory() public {
        LiquidityCommitmentCertificate lcc0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        LiquidityCommitmentCertificate lcc1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1)));
        address ua0 = lcc0.underlying();
        address ua1 = lcc1.underlying();
        require(ua0 != address(0) && ua1 != address(0), "CoreHookDirectLPRemoveBucketingTest: native underlying");

        // Use an isolated runner so we can make hard assertions on bucket balances.
        UnwrapInUnlockRunner runner = new UnwrapInUnlockRunner(IPoolManager(address(manager)), liquidityHub);

        // 1) Fund runner with underlying0 and wrap -> LCC0 (direct/wrapped bucket).
        uint256 wrapAmt = 1e12;
        IERC20Minimal(ua0).transfer(address(runner), wrapAmt);
        vm.startPrank(address(runner));
        IERC20Minimal(ua0).approve(liquidityHub, wrapAmt);
        LiquidityHub(payable(liquidityHub)).wrap(address(lcc0), wrapAmt);

        // Approve swap router to pull LCC0 as exact-input payment.
        IERC20Minimal(address(lcc0)).approve(address(swapRouter), type(uint256).max);

        // 2) Swap on the CORE POOL (LCC0 -> LCC1).
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(wrapAmt / 2), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );
        vm.stopPrank();

        // 3) Confirm runner received market-derived LCC1 from PoolManager (bucket-exempt sender).
        (uint256 w1, uint256 m1) = ILCC(address(lcc1)).balancesOf(address(runner));
        assertEq(w1, 0, "expected LCC1 wrapped bucket to be 0 after core swap");
        assertGt(m1, 0, "expected LCC1 market-derived bucket to be > 0 after core swap");

        uint256 runnerUnderlyingBefore = IERC20Minimal(ua1).balanceOf(address(runner));
        uint256 factoryUnderlyingBefore = IERC20Minimal(ua1).balanceOf(marketFactory);

        // 4) Unwrap market-derived LCC1. This must withdraw underlying from market and bubble it to the Hub (not Factory).
        vm.recordLogs();
        runner.run(address(lcc1), m1);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bool sawPmToHub = false;
        bool sawPmToFactory = false;
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory e = entries[i];
            if (e.emitter != ua1) continue;
            if (e.topics.length == 0 || e.topics[0] != transferTopic) continue;

            address from = address(uint160(uint256(e.topics[1])));
            address to = address(uint160(uint256(e.topics[2])));
            if (from == address(manager) && to == address(liquidityHub)) sawPmToHub = true;
            if (from == address(manager) && to == marketFactory) sawPmToFactory = true;
        }

        assertTrue(sawPmToHub, "expected underlying to transfer PoolManager -> LiquidityHub during unwrap");
        assertFalse(sawPmToFactory, "underlying must not bubble into MarketFactory during unwrap");

        assertGt(
            IERC20Minimal(ua1).balanceOf(address(runner)),
            runnerUnderlyingBefore,
            "runner should receive underlying after unwrap"
        );
        assertEq(IERC20Minimal(ua1).balanceOf(marketFactory), factoryUnderlyingBefore);
    }

    function test_singleTx_decrease_unwrap_sweep_movesUnderlyingViaHub_andBurnsMarketDerivedLCC() public {
        DecreaseUnwrapSweepState memory s;
        s.lcc0 = Currency.unwrap(corePoolKey.currency0);
        s.lcc1 = Currency.unwrap(corePoolKey.currency1);
        s.ua0 = LiquidityCommitmentCertificate(payable(s.lcc0)).underlying();
        s.ua1 = LiquidityCommitmentCertificate(payable(s.lcc1)).underlying();
        require(s.ua0 != address(0) && s.ua1 != address(0), "CoreHookDirectLPRemoveBucketingTest: native underlying");

        // Use a multicall/action-enabled PositionManager so unwrap + sweep happen inside PoolManager.unlock.
        FietPositionManager posm = new FietPositionManager(
            IPoolManager(address(manager)), permit2, 500_000, uniPositionDescriptor, weth9, liquidityHub
        );

        // Mint a DirectLP position owned by LP (fund+wrap first).
        s.tokenId = posm.nextTokenId();
        s.liq = 1e12;
        {
            uint256 wrapAmt = 5e18;
            IERC20Minimal(s.ua0).transfer(lp, wrapAmt);
            IERC20Minimal(s.ua1).transfer(lp, wrapAmt);

            vm.startPrank(lp);
            IERC20Minimal(s.ua0).approve(liquidityHub, wrapAmt);
            LiquidityHub(liquidityHub).wrap(s.lcc0, wrapAmt);
            IERC20Minimal(s.ua1).approve(liquidityHub, wrapAmt);
            LiquidityHub(liquidityHub).wrap(s.lcc1, wrapAmt);

            IERC20Minimal(s.lcc0).approve(address(permit2), type(uint256).max);
            IERC20Minimal(s.lcc1).approve(address(permit2), type(uint256).max);
            permit2.approve(s.lcc0, address(posm), type(uint160).max, type(uint48).max);
            permit2.approve(s.lcc1, address(posm), type(uint160).max, type(uint48).max);

            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(
                corePoolKey, int24(-60), int24(60), s.liq, type(uint128).max, type(uint128).max, lp, ZERO_BYTES
            );
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
            posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
            vm.stopPrank();
        }

        s.lpUa0Before = IERC20Minimal(s.ua0).balanceOf(lp);
        s.lpUa1Before = IERC20Minimal(s.ua1).balanceOf(lp);
        s.factoryUa0Before = IERC20Minimal(s.ua0).balanceOf(marketFactory);
        s.factoryUa1Before = IERC20Minimal(s.ua1).balanceOf(marketFactory);

        // Execute the full flow in a single transaction from the LP:
        // DECREASE -> TAKE_PAIR (to PosM) -> unwrap (custom action) -> SWEEP underlyings to LP.
        bytes memory actions2 = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR),
            uint8(0x80),
            uint8(0x80),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params2 = new bytes[](6);
        params2[0] = abi.encode(s.tokenId, s.liq, type(uint128).min, type(uint128).min, bytes(""));
        params2[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, address(posm));
        params2[2] = abi.encode(s.lcc0, uint256(0)); // unwrap full market-derived balance
        params2[3] = abi.encode(s.lcc1, uint256(0)); // unwrap full market-derived balance
        params2[4] = abi.encode(Currency.wrap(s.ua0), lp);
        params2[5] = abi.encode(Currency.wrap(s.ua1), lp);

        vm.recordLogs();
        vm.prank(lp);
        posm.modifyLiquidities(abi.encode(actions2, params2), block.timestamp + 3600);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Assert underlying "bubbles" from PoolManager into LiquidityHub during unwrap, never into MarketFactory.
        (bool sawPmToHub0, bool sawPmToFactory0) = _scanUnderlyingTransfers(entries, s.ua0);
        (bool sawPmToHub1, bool sawPmToFactory1) = _scanUnderlyingTransfers(entries, s.ua1);
        assertTrue(sawPmToHub0 || sawPmToHub1, "expected PM -> Hub transfer for at least one underlying");
        assertFalse(sawPmToFactory0, "underlying0 must not bubble into MarketFactory");
        assertFalse(sawPmToFactory1, "underlying1 must not bubble into MarketFactory");

        // LCC outcomes: PosM should have unwrapped everything it received.
        assertEq(_sumLccBuckets(s.lcc0, address(posm)), 0, "posm should not retain LCC0 after unwrap+sweep");
        assertEq(_sumLccBuckets(s.lcc1, address(posm)), 0, "posm should not retain LCC1 after unwrap+sweep");

        // Underlying outcomes: LP should receive underlying from the sweep, and factory must not receive anything.
        assertGt(IERC20Minimal(s.ua0).balanceOf(lp), s.lpUa0Before, "LP should receive underlying0 after flow");
        assertGt(IERC20Minimal(s.ua1).balanceOf(lp), s.lpUa1Before, "LP should receive underlying1 after flow");
        assertEq(
            IERC20Minimal(s.ua0).balanceOf(marketFactory), s.factoryUa0Before, "factory must not receive underlying0"
        );
        assertEq(
            IERC20Minimal(s.ua1).balanceOf(marketFactory), s.factoryUa1Before, "factory must not receive underlying1"
        );
    }

    function test_multicall_threeCall_decrease_then_unwrapTo_then_sweepPosm() public {
        // Use the default PositionManager and a separate multicaller that performs:
        //   (1) PosM unlock: DECREASE+TAKE_PAIR to multicaller
        //   (2) Separate PoolManager unlock: unwrapTo(lcc, to=EOA)
        //   (3) Post-unwrap sweep of any residual PosM balances
        PositionManager posm = uniPositionManager;
        ThreeCallMulticallState memory t;
        t.lcc0 = Currency.unwrap(corePoolKey.currency0);
        t.lcc1 = Currency.unwrap(corePoolKey.currency1);
        t.ua0 = LiquidityCommitmentCertificate(payable(t.lcc0)).underlying();
        t.ua1 = LiquidityCommitmentCertificate(payable(t.lcc1)).underlying();
        require(t.ua0 != address(0) && t.ua1 != address(0), "CoreHookDirectLPRemoveBucketingTest: native underlying");

        // Mint a DirectLP position owned by LP (fund+wrap first).
        t.tokenId = posm.nextTokenId();
        t.liq = 1e12;
        {
            uint256 wrapAmt = 5e18;
            IERC20Minimal(t.ua0).transfer(lp, wrapAmt);
            IERC20Minimal(t.ua1).transfer(lp, wrapAmt);

            vm.startPrank(lp);
            IERC20Minimal(t.ua0).approve(liquidityHub, wrapAmt);
            LiquidityHub(liquidityHub).wrap(t.lcc0, wrapAmt);
            IERC20Minimal(t.ua1).approve(liquidityHub, wrapAmt);
            LiquidityHub(liquidityHub).wrap(t.lcc1, wrapAmt);

            IERC20Minimal(t.lcc0).approve(address(permit2), type(uint256).max);
            IERC20Minimal(t.lcc1).approve(address(permit2), type(uint256).max);
            permit2.approve(t.lcc0, address(posm), type(uint160).max, type(uint48).max);
            permit2.approve(t.lcc1, address(posm), type(uint160).max, type(uint48).max);

            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(
                corePoolKey, int24(-60), int24(60), t.liq, type(uint128).max, type(uint128).max, lp, ZERO_BYTES
            );
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
            posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
            vm.stopPrank();
        }

        ThreeStepDecreaseUnwrapSweepMulticaller mc =
            new ThreeStepDecreaseUnwrapSweepMulticaller(IPoolManager(address(manager)), liquidityHub, address(posm));
        t.mc = address(mc);

        // LP approves multicaller to manage the position token (so it can be the PosM "locker" for decrease).
        vm.prank(lp);
        posm.approve(t.mc, t.tokenId);

        t.lpUa0Before = IERC20Minimal(t.ua0).balanceOf(lp);
        t.lpUa1Before = IERC20Minimal(t.ua1).balanceOf(lp);
        t.factoryUa0Before = IERC20Minimal(t.ua0).balanceOf(marketFactory);
        t.factoryUa1Before = IERC20Minimal(t.ua1).balanceOf(marketFactory);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(
            ThreeStepDecreaseUnwrapSweepMulticaller.step1_decreaseAndTakePairToSelf,
            (t.tokenId, t.liq, corePoolKey.currency0, corePoolKey.currency1)
        );
        calls[1] =
            abi.encodeCall(ThreeStepDecreaseUnwrapSweepMulticaller.step2_unwrapTo_withOwnUnlock, (t.lcc0, t.lcc1, lp));
        calls[2] = abi.encodeCall(
            ThreeStepDecreaseUnwrapSweepMulticaller.step3_sweepPosmTo, (Currency.wrap(t.ua0), Currency.wrap(t.ua1), lp)
        );

        vm.recordLogs();
        vm.prank(lp);
        mc.multicall(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Underlying movement: must bubble PoolManager -> LiquidityHub during unwrap, never into MarketFactory.
        (bool sawPmToHub0, bool sawPmToFactory0) = _scanUnderlyingTransfers(entries, t.ua0);
        (bool sawPmToHub1, bool sawPmToFactory1) = _scanUnderlyingTransfers(entries, t.ua1);
        assertTrue(sawPmToHub0 || sawPmToHub1, "expected PM -> Hub transfer for at least one underlying");
        assertFalse(sawPmToFactory0, "underlying0 must not bubble into MarketFactory");
        assertFalse(sawPmToFactory1, "underlying1 must not bubble into MarketFactory");

        // LCC outcomes: multicaller should have unwrapped everything it received.
        assertEq(_sumLccBuckets(t.lcc0, t.mc), 0, "Multicaller should not retain LCC0 after unwrapTo");
        assertEq(_sumLccBuckets(t.lcc1, t.mc), 0, "Multicaller should not retain LCC1 after unwrapTo");

        // Underlying outcomes: LP receives underlying, MarketFactory receives nothing.
        assertGt(IERC20Minimal(t.ua0).balanceOf(lp), t.lpUa0Before, "LP should receive underlying0 after flow");
        assertGt(IERC20Minimal(t.ua1).balanceOf(lp), t.lpUa1Before, "LP should receive underlying1 after flow");
        assertEq(
            IERC20Minimal(t.ua0).balanceOf(marketFactory), t.factoryUa0Before, "factory must not receive underlying0"
        );
        assertEq(
            IERC20Minimal(t.ua1).balanceOf(marketFactory), t.factoryUa1Before, "factory must not receive underlying1"
        );
    }
}

