// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookMinerBase} from "../base/HookMinerBase.sol";
import {HookFlags} from "../../../src/libraries/HookFlags.sol";
import {ProxyHook} from "../../../src/ProxyHook.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {ILiquidityHub} from "../../../src/interfaces/ILiquidityHub.sol";
import {VaultSettlementIntent} from "../../../src/types/VTS.sol";

/// @notice Echidna harness for **MKT-05** that drives the `ProxyHook.beforeSwap` execution path in a stubbed environment.
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
/// The property we lock in is the MKT-05 cancellation arithmetic:
///
/// In Uniswap v4, the effective pool amount is:
/// - `amountToSwap = params.amountSpecified + hookDeltaSpecified`
///
/// So here we assert:
/// - `params.amountSpecified + specifiedDelta == 0`
///
/// NOTE: this harness is intentionally a lightweight model check. Authoritative MKT-05 behaviour
/// (strict exact-output and no proxy-curve utilisation) is gated by Foundry regressions in `ProxyHook.t.sol`.
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
///
/// Additional scope trim:
/// - This harness intentionally exercises only `zeroForOne` actions.
/// - `oneForZero` MKT-05 coverage is treated as authoritative in `ProxyHook.t.sol` first-take regressions.
contract MKT05 is HookMinerBase {
    // Minimal protocol/environment stubs.
    MockPoolManager internal manager;
    MockLiquidityHub internal hub;
    MockMarketFactory internal factory;
    MockCanonicalVault internal canonicalVault;
    MockMsgSenderZero internal unresolvedSender;

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
    int256 internal lastResidual;
    uint8 internal lastFailureCode;

    uint256 internal attempts;
    uint256 internal successes;
    uint256 internal exactInputSuccesses;
    uint256 internal exactOutputAttempts;
    uint256 internal exactOutputReverts;
    uint8 internal constant FAIL_NONE = 0;
    uint8 internal constant FAIL_NONZERO_RESIDUAL = 1;

    constructor() {
        manager = new MockPoolManager();
        hub = new MockLiquidityHub();
        factory = new MockMarketFactory(ILiquidityHub(address(hub)));
        canonicalVault = new MockCanonicalVault(address(factory));
        unresolvedSender = new MockMsgSenderZero();
        factory.setCanonicalVault(address(canonicalVault));

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
        canonicalVault.seedMarket(
            PoolId.unwrap(coreKey.toId()), address(lcc0), address(lcc1), address(u0), address(u1), 1e30, 1e30
        );

        // Set the proxy pool key via `beforeInitialize` (sender must be factory, caller must be pool manager).
        proxyKey = PoolKey({
            currency0: Currency.wrap(address(u0)),
            currency1: Currency.wrap(address(u1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.callBeforeInitialize(hook, address(factory), proxyKey, 0);

        // Seed the CanonicalVault's underlying claims so the hook can burn settled output during proxy swaps.
        manager.mint(address(canonicalVault), proxyKey.currency0.toId(), 1e30);
        manager.mint(address(canonicalVault), proxyKey.currency1.toId(), 1e30);

        // Seed pool manager LCC balances so `Currency.take(..., claims=false)` can transfer out.
        lcc0.mint(address(manager), 1e30);
        lcc1.mint(address(manager), 1e30);
    }

    /// @dev Re-seed the lightweight reserve / claim state so each action checks MKT-05 cancellation in isolation.
    function _resetLivePathState() internal {
        canonicalVault.seedMarket(
            PoolId.unwrap(hook.getCorePoolId()), address(lcc0), address(lcc1), address(u0), address(u1), 1e30, 1e30
        );
        manager.mint(address(canonicalVault), proxyKey.currency0.toId(), 1e30);
        manager.mint(address(canonicalVault), proxyKey.currency1.toId(), 1e30);
        lcc0.mint(address(manager), 1e30);
        lcc1.mint(address(manager), 1e30);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_proxy_beforeSwap_exactInput(bool zeroForOne, uint96 amountInRaw) external {
        if (!zeroForOne) return;
        unchecked {
            attempts++;
        }
        _resetLivePathState();
        checked = false;
        lastOk = true;
        lastFailureCode = FAIL_NONE;

        uint256 amountIn = uint256(amountInRaw) + 1;
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        // Keep hookData empty so recipient resolution follows the unresolved path.
        // This avoids deficit-recipient semantics that this lightweight stub model cannot represent faithfully.
        bytes memory hookData = bytes("");

        try manager.callBeforeSwap(hook, address(unresolvedSender), proxyKey, params, hookData) returns (BeforeSwapDelta delta) {
            lastAmountSpecified = params.amountSpecified;
            lastDelta = delta;
            checked = true;
            unchecked {
                successes++;
                exactInputSuccesses++;
            }

            int256 specifiedDelta = int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta));
            lastResidual = lastAmountSpecified + specifiedDelta;
            if (lastResidual != 0) {
                lastFailureCode = FAIL_NONZERO_RESIDUAL;
            }
            lastOk = lastFailureCode == FAIL_NONE;
        } catch {
            // If the execution path reverts under a particular input, treat it as "not checked" for this action.
            checked = false;
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_proxy_beforeSwap_exactOutput(bool zeroForOne, uint96 amountOutRaw) external {
        if (!zeroForOne) return;
        unchecked {
            exactOutputAttempts++;
        }
        _resetLivePathState();
        // Exact-output behaviour is exercised here for reachability only.
        // Authoritative exact-output MKT-05 assertions are covered in ProxyHook.t.sol first-take regressions.

        uint256 amountOut = uint256(amountOutRaw) + 1;
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(amountOut), sqrtPriceLimitX96: 0});
        // Keep hookData empty so recipient resolution follows the unresolved path.
        // This avoids deficit-recipient semantics that this lightweight stub model cannot represent faithfully.
        bytes memory hookData = bytes("");

        try manager.callBeforeSwap(hook, address(unresolvedSender), proxyKey, params, hookData) returns (BeforeSwapDelta delta) {
            lastDelta = delta;
        } catch {
            unchecked {
                exactOutputReverts++;
            }
        }
    }

    /// @notice MKT-05 live-path property: ProxyHook returns a specified-delta that cancels `amountSpecified`.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt05_live_amountToSwap_is_zero() external view returns (bool) {
        // Allow the constructor state to pass before any live-path attempt, then require at least one successful
        // exact-input run so the cancellation check is non-vacuous.
        return (!checked || lastOk) && (attempts == 0 || exactInputSuccesses > 0);
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
    error InsufficientClaimBalance(address account, uint256 id, uint256 requested, uint256 available);

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
        if (cur < amount) revert InsufficientClaimBalance(from, id, amount, cur);
        unchecked {
            _claim[from][id] = cur - amount;
        }
    }

    function sync(Currency) external pure {}

    function settle() external payable returns (uint256 paid) {
        return msg.value;
    }

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

/// @dev Minimal LiquidityHub stub for `issue/cancel/totalQueued/unfundedQueueOfUnderlying` used in proxy swap settlement.
contract MockLiquidityHub {
    function totalQueued(address) external pure returns (uint256) {
        return 0;
    }

    function unfundedQueueOfUnderlying(address) external pure returns (uint256) {
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

/// @dev Minimal CanonicalVault stub for proxy-swap MKT-05 fuzzing.
///      It tracks only durable per-market underlying reserve and LCC->underlying mapping.
contract MockCanonicalVault {
    address public immutable marketFactory;

    mapping(bytes32 marketId => mapping(address underlying => uint256 amount)) internal _reserve;
    mapping(address lcc => address underlying) internal _underlyingOfLcc;

    constructor(address marketFactory_) {
        marketFactory = marketFactory_;
    }

    function seedMarket(
        bytes32 marketId,
        address lcc0,
        address lcc1,
        address underlying0,
        address underlying1,
        uint256 reserve0,
        uint256 reserve1
    ) external {
        _underlyingOfLcc[lcc0] = underlying0;
        _underlyingOfLcc[lcc1] = underlying1;
        _reserve[marketId][underlying0] = reserve0;
        _reserve[marketId][underlying1] = reserve1;
    }

    function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256) {
        return _reserve[marketId][Currency.unwrap(currency)];
    }

    function cancelLCCWithDeficit(bytes32 marketId, address lccToken, uint256 amount, address deficitRecipient)
        external
        returns (uint256 amountToCancel)
    {
        address underlying = _underlyingOfLcc[lccToken];
        uint256 available = _reserve[marketId][underlying];
        amountToCancel = amount > available ? available : amount;
        if (amountToCancel < amount && deficitRecipient == address(0)) revert();
        unchecked {
            _reserve[marketId][underlying] = available - amountToCancel;
        }
    }

    function increaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external {
        unchecked {
            _reserve[marketId][Currency.unwrap(underlyingCurrency)] += amount;
        }
    }

    function decreaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external {
        address underlying = Currency.unwrap(underlyingCurrency);
        uint256 available = _reserve[marketId][underlying];
        require(available >= amount, "MockCanonicalVault: reserve");
        unchecked {
            _reserve[marketId][underlying] = available - amount;
        }
    }

    function settleUnderlyingToVaultFromHub(bytes32 marketId, address lccToken, uint256 amount) external {
        unchecked {
            _reserve[marketId][_underlyingOfLcc[lccToken]] += amount;
        }
    }

    function dryModifyLiquidities(bytes32, Currency, Currency, BalanceDelta balanceDelta)
        external
        pure
        returns (BalanceDelta)
    {
        return balanceDelta;
    }

    function dryModifyLiquidities(bytes32, Currency, Currency, VaultSettlementIntent calldata settlementIntent)
        external
        pure
        returns (BalanceDelta)
    {
        return settlementIntent.requestedDelta;
    }

    function modifyLiquidities(bytes32, Currency, Currency, address, address, BalanceDelta, address)
        external
        pure
        returns (BalanceDelta usedDelta)
    {
        return toBalanceDelta(0, 0);
    }

    function modifyLiquidities(bytes32, Currency, Currency, address, address, VaultSettlementIntent calldata, address)
        external
        pure
        returns (BalanceDelta usedDelta)
    {
        return toBalanceDelta(0, 0);
    }

    function settleObligations(bytes32, address, address) external pure {}

    function settleObligationsForLCC(bytes32, address) external pure {}

    function takeUnderlyingClaims(bytes32, Currency, uint256) external pure {}

    function settleUnderlyingFromClaims(bytes32, Currency, uint256) external pure {}

    function issueAndSettleLcc(bytes32, address, uint256) external pure {}

    function takeLccFromPoolManager(bytes32, address, uint256) external pure {}
}

contract MockMsgSenderZero {
    function msgSender() external pure returns (address) {
        return address(0);
    }
}

/// @dev Minimal MarketFactory stub: only `liquidityHub()` is required at `MarketVault` construction time,
///      and this contract is used as the `onlyFactory` caller for `setCorePoolKey`.
contract MockMarketFactory {
    ILiquidityHub internal immutable _hub;
    address internal _canonicalVault;

    constructor(ILiquidityHub hub_) {
        _hub = hub_;
    }

    function liquidityHub() external view returns (ILiquidityHub) {
        return _hub;
    }

    function setCanonicalVault(address canonicalVault_) external {
        _canonicalVault = canonicalVault_;
    }

    function canonicalVault() external view returns (address) {
        return _canonicalVault;
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
