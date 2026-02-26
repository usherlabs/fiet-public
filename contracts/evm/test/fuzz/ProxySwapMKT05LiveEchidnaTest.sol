// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookMinerBase} from "./base/HookMinerBase.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";

/// @notice Echidna harness for **MKT-05** that drives the *real* `ProxyHook.beforeSwap` execution path.
///
/// ## What Echidna is doing here (stateful fuzzing)
///
/// Echidna deploys this contract once, then repeatedly calls arbitrary sequences of `action_*` methods with
/// adversarial inputs. After (and during) those sequences, it evaluates `echidna_*` properties and treats any
/// `false` as a counterexample.
///
/// This harness uses a standard "checked/lastOk" pattern:
/// - Each action attempts a real `ProxyHook.beforeSwap` call and, if it succeeds, records the last inputs/outputs.
/// - The property asserts the recorded run satisfied the MKT-05 cancellation relation.
/// - If an action reverts, we mark the run as "not checked" so Echidna can continue exploring other paths in the
///   sequence (we still want reachability across different input shapes).
///
/// ## What is actually being tested (behavioural assurance)
///
/// This test is **not** a pure algebraic model. It executes `ProxyHook.beforeSwap` end-to-end against minimal stubs:
/// - The hook is deployed at a flags-compliant address (hook permission bits are enforced at deployment).
/// - `beforeInitialize` is called via the mock PoolManager to set `proxyPoolKey` (as it would be in production).
/// - `setCorePoolKey` is called from the mock MarketFactory to satisfy `onlyFactory` gating.
/// - The swap flow executes the real `ProxyHook` code that:
///   - determines direction alignment (`_buildSwapContext`),
///   - performs a core swap (`poolManager.swap`),
///   - settles via Hub issue/cancel, and
///   - returns the `BeforeSwapDelta` that is supposed to cancel the proxy pool's swap amount.
///
/// The property we lock in is the MKT-05 mechanical consequence in v4-core:
///
/// In Uniswap v4, the effective pool amount is:
/// - `amountToSwap = params.amountSpecified + hookDeltaSpecified`
///
/// MKT-05 requires **no residual proxy AMM swap path**, so we assert:
/// - `params.amountSpecified + specifiedDelta == 0`
///
/// If a regression flips a sign, swaps the legs, or otherwise mis-builds the returned delta in `ProxyHook.beforeSwap`,
/// this harness should fail.
///
/// ## What is deliberately NOT being tested (scope boundaries)
///
/// To keep Echidna runs fast and targeted, the environment is stubbed:
/// - `MockPoolManager.swap` returns a simple 1:1 `BalanceDelta` (it does not simulate price impact, ticks, fees, etc.).
/// - The mock Hub implements only `issue/cancel/totalQueued` semantics needed for the proxy settlement path.
/// - We seed "claim balances" so `_cancelLCCWithDeficit` never enters deficit/overflow sub-paths; this harness is
///   focused on the **returned delta cancellation**, not deficit accounting.
///
/// This means the harness **does not** prove:
/// - swaps are feasible under real liquidity constraints,
/// - proxy `slot0` remains unchanged after a full PoolManager swap,
/// - settlement correctness across queued/deficit scenarios, or
/// - invariants that require a real PoolManager implementation.
///
/// Those are covered (or should be covered) elsewhere via Foundry integration/unit tests and other harnesses.
contract ProxySwapMKT05LiveEchidnaTest is HookMinerBase {
    // Minimal protocol/environment stubs.
    MockPoolManager internal manager;
    MockLiquidityHub internal hub;
    MockMarketFactory internal factory;

    // Underlyings and LCCs (core pool currencies are LCCs, proxy pool currencies are underlyings).
    MockERC20 internal u0;
    MockERC20 internal u1;
    MockLCC internal lcc0;
    MockLCC internal lcc1;

    ProxyHook internal hook;
    PoolKey internal proxyKey;

    bool internal checked;
    bool internal lastOk;
    int256 internal lastAmountSpecified;
    BeforeSwapDelta internal lastDelta;

    constructor() {
        manager = new MockPoolManager();
        hub = new MockLiquidityHub();
        factory = new MockMarketFactory(ILiquidityHub(address(hub)));

        u0 = new MockERC20("UNDER0", "U0");
        u1 = new MockERC20("UNDER1", "U1");
        lcc0 = new MockLCC("LCC0", "L0", address(u0));
        lcc1 = new MockLCC("LCC1", "L1", address(u1));

        // Deploy ProxyHook to a flags-compliant address (Uniswap v4 hook permission bits).
        bytes memory creationCode = type(ProxyHook).creationCode;
        bytes memory args = abi.encode(address(manager), address(factory));
        bytes32 salt = _findSalt(HookFlags.PROXY_HOOK_FLAGS, creationCode, args);
        hook = new ProxyHook{salt: salt}(address(manager), address(factory));
        require(
            address(hook) == _computeCreate2(address(this), salt, abi.encodePacked(creationCode, args)),
            "ProxyHook deploy mismatch"
        );

        // Set the core pool key (LCC pair) via factory-gated method.
        PoolKey memory coreKey = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        factory.callSetCorePoolKey(hook, coreKey);

        // Set the proxy pool key via `beforeInitialize` (sender must be factory, caller must be pool manager).
        proxyKey = PoolKey({
            currency0: Currency.wrap(address(u0)),
            currency1: Currency.wrap(address(u1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.callBeforeInitialize(hook, address(factory), proxyKey, 0);

        // Seed the MarketVault claim balances so `_cancelLCCWithDeficit` never enters deficit paths.
        manager.mint(address(hook), proxyKey.currency0.toId(), 1e30);
        manager.mint(address(hook), proxyKey.currency1.toId(), 1e30);

        // Seed pool manager LCC balances so `Currency.take(..., claims=false)` can transfer out.
        lcc0.mint(address(manager), 1e30);
        lcc1.mint(address(manager), 1e30);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_proxy_beforeSwap_exactInput(bool zeroForOne, uint96 amountInRaw) external {
        checked = false;
        lastOk = true;

        uint256 amountIn = uint256(amountInRaw) + 1;
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        // Use an explicit non-sentinel recipient so `_determineExcessRecipient` resolves without locker introspection.
        bytes memory hookData = abi.encode(address(0xBEEF));

        try manager.callBeforeSwap(hook, address(0xCAFE), proxyKey, params, hookData) returns (BeforeSwapDelta delta) {
            lastAmountSpecified = params.amountSpecified;
            lastDelta = delta;
            checked = true;

            int256 specifiedDelta = int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta));
            lastOk = lastAmountSpecified + specifiedDelta == 0;
        } catch {
            // If the execution path reverts under a particular input, treat it as "not checked" for this action.
            checked = false;
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_proxy_beforeSwap_exactOutput(bool zeroForOne, uint96 amountOutRaw) external {
        checked = false;
        lastOk = true;

        uint256 amountOut = uint256(amountOutRaw) + 1;
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(amountOut), sqrtPriceLimitX96: 0});
        bytes memory hookData = abi.encode(address(0xBEEF));

        try manager.callBeforeSwap(hook, address(0xCAFE), proxyKey, params, hookData) returns (BeforeSwapDelta delta) {
            lastAmountSpecified = params.amountSpecified;
            lastDelta = delta;
            checked = true;

            int256 specifiedDelta = int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta));
            lastOk = lastAmountSpecified + specifiedDelta == 0;
        } catch {
            checked = false;
        }
    }

    /// @notice MKT-05 live-path property: ProxyHook returns a specified-delta that cancels `amountSpecified`.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt05_live_amountToSwap_is_zero() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt05_live_smoke() external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal PoolManager stub sufficient for driving `ProxyHook.beforeSwap` and claim-balance reads.
///      It implements only the selectors actually exercised by the hook and `CurrencySettler`.
contract MockPoolManager {
    mapping(address owner => mapping(uint256 id => uint256 bal)) internal _claim;

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _claim[owner][id];
    }

    function mint(address to, uint256 id, uint256 amount) external {
        unchecked {
            _claim[to][id] += amount;
        }
    }

    function burn(address from, uint256 id, uint256 amount) external {
        uint256 cur = _claim[from][id];
        _claim[from][id] = amount >= cur ? 0 : (cur - amount);
    }

    function sync(Currency) external pure {}

    function settle() external payable {}

    function take(Currency currency, address recipient, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool ok,) = payable(recipient).call{value: amount}("");
            require(ok, "MockPoolManager: native take failed");
            return;
        }
        require(IERC20Minimal(Currency.unwrap(currency)).transfer(recipient, amount), "MockPoolManager: take failed");
    }

    function swap(PoolKey calldata, SwapParams calldata params, bytes calldata) external pure returns (BalanceDelta) {
        uint256 magnitude =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Simple 1:1 "price" for the core swap; only the delta sign/orientation matters for this harness.
        int128 amt = int128(uint128(magnitude));

        if (params.zeroForOne) {
            // token0 in (negative), token1 out (positive)
            return toBalanceDelta(-amt, amt);
        } else {
            // token1 in (negative), token0 out (positive)
            return toBalanceDelta(amt, -amt);
        }
    }

    function callBeforeInitialize(ProxyHook h, address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        returns (bytes4)
    {
        return h.beforeInitialize(sender, key, sqrtPriceX96);
    }

    function callBeforeSwap(
        ProxyHook h,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (BeforeSwapDelta delta) {
        (, delta,) = h.beforeSwap(sender, key, params, hookData);
    }
}

/// @dev Minimal LiquidityHub stub for `issue/cancel/totalQueued` used in proxy swap settlement.
contract MockLiquidityHub {
    function totalQueued(address) external pure returns (uint256) {
        return 0;
    }

    function issue(address lccToken, address to, uint256 amount) external {
        MockLCC(lccToken).mint(to, amount);
    }

    function cancel(address lccToken, address from, uint256 amount) external {
        MockLCC(lccToken).burn(from, amount);
    }

    function prepareSettle(address, uint256) external pure {}

    function confirmTake(address, uint256, bool) external pure {}
}

/// @dev Minimal MarketFactory stub: only `liquidityHub()` is required at `MarketVault` construction time,
///      and this contract is used as the `onlyFactory` caller for `setCorePoolKey`.
contract MockMarketFactory {
    ILiquidityHub internal immutable _hub;

    constructor(ILiquidityHub hub_) {
        _hub = hub_;
    }

    function liquidityHub() external view returns (ILiquidityHub) {
        return _hub;
    }

    function callSetCorePoolKey(ProxyHook h, PoolKey calldata coreKey) external {
        h.setCorePoolKey(coreKey);
    }

    // Included for completeness/safety if other ProxyHook paths are exercised in future.
    function bounds(address) external pure returns (bool) {
        return true;
    }

    function coreHook() external pure returns (address) {
        return address(0);
    }

    function corePoolToProxyHook(PoolId) external pure returns (address) {
        return address(0);
    }
}

/// @dev Minimal ERC20 implementing `IERC20Minimal` for CurrencySettler transfers.
contract MockERC20 is IERC20Minimal {
    string public name;
    string public symbol;

    uint8 public constant decimals = 18;

    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) internal _allow;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function totalSupply() external pure returns (uint256) {
        return type(uint256).max;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _bal[owner];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= amount, "MockERC20: allowance");
        unchecked {
            _allow[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "MockERC20: to");
        uint256 b = _bal[from];
        require(b >= amount, "MockERC20: balance");
        unchecked {
            _bal[from] = b - amount;
            _bal[to] += amount;
        }
    }

    function _mint(address to, uint256 amount) internal {
        unchecked {
            _bal[to] += amount;
        }
    }

    function _burn(address from, uint256 amount) internal {
        uint256 b = _bal[from];
        require(b >= amount, "MockERC20: burn");
        unchecked {
            _bal[from] = b - amount;
        }
    }
}

/// @dev Minimal LCC mock (ERC20 + `underlying()` + burn/mint hooks for the hub).
contract MockLCC is MockERC20 {
    address internal immutable _underlyingAsset;

    constructor(string memory name_, string memory symbol_, address underlyingAsset_) MockERC20(name_, symbol_) {
        _underlyingAsset = underlyingAsset_;
    }

    function underlying() external view returns (address) {
        return _underlyingAsset;
    }

    function balancesOf(address account) external view returns (uint256 wrapped, uint256 marketDerived) {
        // The ProxyHook swap path only requires ERC20 balance accounting; bucket semantics are out of scope here.
        wrapped = _bal[account];
        marketDerived = 0;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

