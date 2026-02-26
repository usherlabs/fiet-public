// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MarketVault} from "../../src/modules/MarketVault.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {MockERC20} from "../_mocks/MockERC20.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";

contract MockPoolManager_Min {
    mapping(address => mapping(uint256 => uint256)) internal _claimBalances;

    function setClaimBalance(address owner, Currency currency, uint256 amount) external {
        _claimBalances[owner][currency.toId()] = amount;
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _claimBalances[owner][id];
    }

    function burn(address from, uint256 id, uint256 amount) external {
        uint256 bal = _claimBalances[from][id];
        require(bal >= amount, "burn>bal");
        _claimBalances[from][id] = bal - amount;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _claimBalances[to][id] += amount;
    }

    function sync(Currency) external pure {}

    function settle() external payable returns (uint256 paid) {
        // For unit tests we don't model transient deltas; just satisfy the interface ABI.
        // Returning msg.value makes native-settle behave sensibly; ERC20 settles will return 0.
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "eth take failed");
        } else {
            // PoolManager holds the underlying ERC20; transfer it out.
            MockERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    receive() external payable {}
}

contract MockLiquidityHub_Min {
    mapping(address => uint256) internal _queued;

    // observability
    address public lastConfirmLcc;
    uint256 public lastConfirmAmount;
    bool public lastConfirmShouldEmit;
    uint256 public confirmCalls;

    address public lastCancelLcc;
    address public lastCancelFrom;
    uint256 public lastCancelAmount;
    uint256 public cancelCalls;

    address public lastQueueLcc;
    address public lastQueueRecipient;
    uint256 public lastQueueAmount;
    uint256 public queueCalls;

    function setTotalQueued(address lcc, uint256 amount) external {
        _queued[lcc] = amount;
    }

    function totalQueued(address lcc) external view returns (uint256) {
        return _queued[lcc];
    }

    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external {
        lastConfirmLcc = lcc;
        lastConfirmAmount = amount;
        lastConfirmShouldEmit = shouldEmit;
        confirmCalls++;
    }

    function cancel(address lcc, address from, uint256 amount) external {
        lastCancelLcc = lcc;
        lastCancelFrom = from;
        lastCancelAmount = amount;
        cancelCalls++;
    }

    function queueForTransferRecipient(address lcc, address recipient, uint256 amount) external {
        lastQueueLcc = lcc;
        lastQueueRecipient = recipient;
        lastQueueAmount = amount;
        queueCalls++;
    }

    function prepareSettle(address, uint256) external {}

    receive() external payable {}
}

contract MockLiquidityHub_RejectEth {
    mapping(address => uint256) internal _queued;

    address public lastConfirmLcc;
    uint256 public lastConfirmAmount;
    bool public lastConfirmShouldEmit;
    uint256 public confirmCalls;

    function setTotalQueued(address lcc, uint256 amount) external {
        _queued[lcc] = amount;
    }

    function totalQueued(address lcc) external view returns (uint256) {
        return _queued[lcc];
    }

    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external {
        lastConfirmLcc = lcc;
        lastConfirmAmount = amount;
        lastConfirmShouldEmit = shouldEmit;
        confirmCalls++;
    }

    function cancel(address, address, uint256) external {}

    function queueForTransferRecipient(address, address, uint256) external {}

    function prepareSettle(address, uint256) external {}

    receive() external payable {
        revert("reject");
    }
}

contract MockMarketFactory_Min {
    address internal _hub;
    mapping(address => bool) internal _isBound;

    constructor(address hub_) {
        _hub = hub_;
    }

    function liquidityHub() external view returns (address) {
        return _hub;
    }

    function setBound(address who, bool isBound) external {
        _isBound[who] = isBound;
    }

    function bounds(address who) external view returns (bool) {
        return _isBound[who];
    }
}

contract MarketVaultUnitHarness is MarketVault {
    Currency internal _u0;
    Currency internal _u1;
    ILCC internal _l0;
    ILCC internal _l1;
    bytes32 internal _id;

    constructor(IPoolManager pm, address mf, Currency u0, Currency u1, ILCC l0, ILCC l1, bytes32 id_)
        ImmutableState(pm)
        MarketVault(mf)
    {
        _u0 = u0;
        _u1 = u1;
        _l0 = l0;
        _l1 = l1;
        _id = id_;
    }

    function _underlying() internal view override returns (Currency currency0, Currency currency1) {
        return (_u0, _u1);
    }

    function _lccs() internal view override returns (ILCC lccToken0, ILCC lccToken1) {
        return (_l0, _l1);
    }

    function _marketId() internal view override returns (bytes32) {
        return _id;
    }

    // external wrappers for internal functions
    function exposed_takeUnderlyingFromVaultToRecipient(Currency c, address recipient, uint256 amount) external {
        _takeUnderlyingFromVaultToRecipient(c, recipient, amount);
    }

    function exposed_takeUnderlyingFromVaultToHub(ILCC lcc, uint256 amount, bool shouldEmit) external {
        _takeUnderlyingFromVaultToHub(lcc, amount, shouldEmit);
    }

    function exposed_settleUnderlyingToVaultFromSender(Currency c, address sender, uint256 amount) external {
        _settleUnderlyingToVaultFromSender(c, sender, amount);
    }

    function exposed_settleObligationsForLCC(ILCC lcc) external {
        _settleObligationsForLCC(lcc);
    }

    function exposed_cancelLCCWithDeficit(PoolId poolId, ILCC lcc, uint256 amount, address deficitRecipient)
        external
        returns (uint256)
    {
        return _cancelLCCWithDeficit(poolId, lcc, amount, deficitRecipient);
    }
}

contract MarketVaultUnitTest is Test {
    function _deployVaultWithHub(address hub)
        internal
        returns (
            MarketVaultUnitHarness vault,
            MockPoolManager_Min pm,
            MockMarketFactory_Min mf,
            MockLCC lccErc20,
            MockLCC lccNative,
            MockERC20 uaErc20
        )
    {
        pm = new MockPoolManager_Min();
        mf = new MockMarketFactory_Min(hub);
        // `MarketVault.receive()` only accepts ETH from protocol-bound senders.
        // In the native path, PoolManager sends ETH to MarketVault, so mark it as bound.
        mf.setBound(address(pm), true);

        uaErc20 = new MockERC20("Underlying", "UA", 18);
        lccErc20 = new MockLCC("MockLCC", "MLCC", 18, address(uaErc20));
        lccNative = new MockLCC("MockLCC-NATIVE", "MLCCN", 18, address(0));

        vault = new MarketVaultUnitHarness(
            IPoolManager(address(pm)),
            address(mf),
            Currency.wrap(address(uaErc20)),
            Currency.wrap(address(0)),
            ILCC(address(lccErc20)),
            ILCC(address(lccNative)),
            keccak256("market")
        );
    }

    function test_receive_revertsWhenSenderNotBound() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,, MockMarketFactory_Min mf,,,) = _deployVaultWithHub(address(hub));

        mf.setBound(address(this), false);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(Errors.InvalidEthSender.selector);
        (bool ok,) = address(vault).call{value: 1 wei}("");
        ok;
    }

    function test_receive_acceptsWhenSenderBound() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,, MockMarketFactory_Min mf,,,) = _deployVaultWithHub(address(hub));

        mf.setBound(address(this), true);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 2 wei}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 2 wei);
    }

    function test_takeUnderlyingFromVaultToRecipient_revertsWhenInsufficientLiquidity() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,,, MockERC20 ua) = _deployVaultWithHub(address(hub));

        Currency c = Currency.wrap(address(ua));
        pm.setClaimBalance(address(vault), c, 4);

        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        vault.exposed_takeUnderlyingFromVaultToRecipient(c, makeAddr("recipient"), 5);
    }

    function test_takeUnderlyingFromVaultToRecipient_erc20_succeedsAndBurnsClaims() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,,, MockERC20 ua) = _deployVaultWithHub(address(hub));

        Currency c = Currency.wrap(address(ua));
        address recipient = makeAddr("recipient");
        uint256 amount = 10;

        pm.setClaimBalance(address(vault), c, amount);
        ua.mint(address(pm), amount);

        vault.exposed_takeUnderlyingFromVaultToRecipient(c, recipient, amount);

        assertEq(ua.balanceOf(recipient), amount);
        assertEq(pm.balanceOf(address(vault), c.toId()), 0);
    }

    function test_takeUnderlyingFromVaultToHub_revertsWhenAmountIsZero() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,,,, MockLCC lccNative,) = _deployVaultWithHub(address(hub));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, 0, 0));
        vault.exposed_takeUnderlyingFromVaultToHub(ILCC(address(lccNative)), 0, true);
    }

    function test_takeUnderlyingFromVaultToHub_native_routesViaVault_andSucceeds() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,, MockLCC lccNative,) = _deployVaultWithHub(address(hub));

        Currency nativeC = Currency.wrap(address(0));
        uint256 amount = 7;

        pm.setClaimBalance(address(vault), nativeC, amount);
        vm.deal(address(pm), amount);

        vault.exposed_takeUnderlyingFromVaultToHub(ILCC(address(lccNative)), amount, true);

        assertEq(address(hub).balance, amount);
        assertEq(hub.lastConfirmLcc(), address(lccNative));
        assertEq(hub.lastConfirmAmount(), amount);
        assertTrue(hub.lastConfirmShouldEmit());
    }

    function test_takeUnderlyingFromVaultToHub_native_revertsWhenHubRejectsEth() public {
        MockLiquidityHub_RejectEth hub = new MockLiquidityHub_RejectEth();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,, MockLCC lccNative,) = _deployVaultWithHub(address(hub));

        Currency nativeC = Currency.wrap(address(0));
        uint256 amount = 3;
        pm.setClaimBalance(address(vault), nativeC, amount);
        vm.deal(address(pm), amount);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "Native transfer to LiquidityHub failed")
        );
        vault.exposed_takeUnderlyingFromVaultToHub(ILCC(address(lccNative)), amount, true);
    }

    function test_settleUnderlyingToVaultFromSender_revertsWhenSenderBalanceInsufficient() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,,,,, MockERC20 ua) = _deployVaultWithHub(address(hub));

        vm.expectRevert(Errors.InsufficientLiquidityToSettle.selector);
        vault.exposed_settleUnderlyingToVaultFromSender(Currency.wrap(address(ua)), makeAddr("sender"), 1);
    }

    function test_settleUnderlyingToVaultFromSender_erc20_transferFromPath_mintsClaims() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,,, MockERC20 ua) = _deployVaultWithHub(address(hub));

        address sender = makeAddr("sender");
        uint256 amount = 11;
        ua.mint(sender, amount);

        vm.prank(sender);
        ua.approve(address(vault), amount);

        Currency c = Currency.wrap(address(ua));
        vault.exposed_settleUnderlyingToVaultFromSender(c, sender, amount);

        assertEq(pm.balanceOf(address(vault), c.toId()), amount);
        assertEq(ua.balanceOf(address(pm)), amount);
    }

    function test_dryModifyLiquidities_adjustsWithdrawalDownToAvailable() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,,, MockERC20 ua) = _deployVaultWithHub(address(hub));

        Currency c0 = Currency.wrap(address(ua));
        pm.setClaimBalance(address(vault), c0, 5);

        BalanceDelta requested = toBalanceDelta(int128(9), int128(0));
        BalanceDelta used = vault.dryModifyLiquidities(requested);

        assertEq(used.amount0(), int128(5));
        assertEq(used.amount1(), int128(0));
    }

    function test_dryModifyLiquidities_keepsWithdrawalWhenSufficient() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,,, MockERC20 ua) = _deployVaultWithHub(address(hub));

        Currency c0 = Currency.wrap(address(ua));
        pm.setClaimBalance(address(vault), c0, 10);

        BalanceDelta requested = toBalanceDelta(int128(9), int128(0));
        BalanceDelta used = vault.dryModifyLiquidities(requested);

        assertEq(used.amount0(), int128(9));
    }

    function test_tryModifyLiquidities_revertsWhenCallerNotBound() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,, MockMarketFactory_Min mf,,,) = _deployVaultWithHub(address(hub));

        mf.setBound(address(this), false);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.tryModifyLiquidities(toBalanceDelta(int128(0), int128(0)));
    }

    function test_tryModifyLiquidities_succeedsWhenCallerBound() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,, MockMarketFactory_Min mf,,,) = _deployVaultWithHub(address(hub));

        mf.setBound(address(this), true);
        BalanceDelta used = vault.tryModifyLiquidities(toBalanceDelta(int128(0), int128(0)));
        assertEq(used.amount0(), int128(0));
        assertEq(used.amount1(), int128(0));
    }

    function test_modifyLiquidities_succeedsAndSettlesObligationsWhenDepositOccurs() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (
            MarketVaultUnitHarness vault,
            MockPoolManager_Min pm,
            MockMarketFactory_Min mf,
            MockLCC lccErc20,,
            MockERC20 ua
        ) = _deployVaultWithHub(address(hub));

        mf.setBound(address(this), true);

        // Provide vault with underlying to settle to manager (deposit == negative delta).
        ua.mint(address(vault), 100);

        // Queue obligations (so the deposit triggers a settlement out to the hub).
        hub.setTotalQueued(address(lccErc20), 20);

        vault.modifyLiquidities(toBalanceDelta(int128(-20), int128(0)));

        assertEq(hub.lastConfirmLcc(), address(lccErc20));
        assertEq(hub.lastConfirmAmount(), 20);
        assertTrue(hub.lastConfirmShouldEmit());
        assertEq(ua.balanceOf(address(hub)), 20);
        assertEq(pm.balanceOf(address(vault), Currency.wrap(address(ua)).toId()), 0);
    }

    function test_modifyLiquidities_succeedsWithReversedLccOrdering() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        MockPoolManager_Min pm = new MockPoolManager_Min();
        MockMarketFactory_Min mf = new MockMarketFactory_Min(address(hub));
        mf.setBound(address(pm), true);

        MockERC20 uaA = new MockERC20("Underlying-A", "UA-A", 18);
        MockERC20 uaB = new MockERC20("Underlying-B", "UA-B", 18);
        MockLCC lccA = new MockLCC("LCC-A", "LCCA", 18, address(uaA));
        MockLCC lccB = new MockLCC("LCC-B", "LCBB", 18, address(uaB));

        (ILCC coreLcc0, ILCC coreLcc1) = address(lccA) < address(lccB)
            ? (ILCC(address(lccA)), ILCC(address(lccB)))
            : (ILCC(address(lccB)), ILCC(address(lccA)));
        address coreUnderlying0 = coreLcc0.underlying();
        address coreUnderlying1 = coreLcc1.underlying();

        Currency proxyU0 = Currency.wrap(coreUnderlying1);
        Currency proxyU1 = Currency.wrap(coreUnderlying0);

        MarketVaultUnitHarness vault = new MarketVaultUnitHarness(
            IPoolManager(address(pm)), address(mf), proxyU0, proxyU1, coreLcc0, coreLcc1, keccak256("reversed-market")
        );

        mf.setBound(address(this), true);
        MockERC20(coreUnderlying0).mint(address(vault), 100);

        vault.modifyLiquidities(toBalanceDelta(int128(-50), int128(0)));

        assertEq(pm.balanceOf(address(vault), Currency.wrap(coreUnderlying0).toId()), 50);
        assertEq(pm.balanceOf(address(vault), Currency.wrap(coreUnderlying1).toId()), 0);
    }

    function test_dryModifyLiquidities_usesCoreOrderingWhenReversed() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        MockPoolManager_Min pm = new MockPoolManager_Min();
        MockMarketFactory_Min mf = new MockMarketFactory_Min(address(hub));
        mf.setBound(address(pm), true);

        MockERC20 uaA = new MockERC20("Underlying-A", "UA-A", 18);
        MockERC20 uaB = new MockERC20("Underlying-B", "UA-B", 18);
        MockLCC lccA = new MockLCC("LCC-A", "LCCA", 18, address(uaA));
        MockLCC lccB = new MockLCC("LCC-B", "LCBB", 18, address(uaB));

        (ILCC coreLcc0, ILCC coreLcc1) = address(lccA) < address(lccB)
            ? (ILCC(address(lccA)), ILCC(address(lccB)))
            : (ILCC(address(lccB)), ILCC(address(lccA)));
        address coreUnderlying0 = coreLcc0.underlying();
        address coreUnderlying1 = coreLcc1.underlying();

        MarketVaultUnitHarness vault = new MarketVaultUnitHarness(
            IPoolManager(address(pm)),
            address(mf),
            Currency.wrap(coreUnderlying1),
            Currency.wrap(coreUnderlying0),
            coreLcc0,
            coreLcc1,
            keccak256("reversed-market-2")
        );

        pm.setClaimBalance(address(vault), Currency.wrap(coreUnderlying0), 7);
        pm.setClaimBalance(address(vault), Currency.wrap(coreUnderlying1), 0);

        BalanceDelta used = vault.dryModifyLiquidities(toBalanceDelta(int128(12), int128(0)));
        assertEq(used.amount0(), int128(7));
        assertEq(used.amount1(), int128(0));
    }

    function test_settleObligationsForLCC_earlyReturnsWhenNothingQueued() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault,,,, MockLCC lccNative,) = _deployVaultWithHub(address(hub));

        hub.setTotalQueued(address(lccNative), 0);
        vault.exposed_settleObligationsForLCC(ILCC(address(lccNative)));
        assertEq(hub.confirmCalls(), 0);
    }

    function test_settleObligationsForLCC_earlyReturnsWhenNoAvailableLiquidity() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,,, MockLCC lccNative,) = _deployVaultWithHub(address(hub));

        hub.setTotalQueued(address(lccNative), 10);
        pm.setClaimBalance(address(vault), Currency.wrap(address(0)), 0);

        vault.exposed_settleObligationsForLCC(ILCC(address(lccNative)));
        assertEq(hub.confirmCalls(), 0);
    }

    function test_cancelLCCWithDeficit_transfersDeficitToRecipientWhenProvided() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,, MockLCC lccErc20,, MockERC20 ua) =
            _deployVaultWithHub(address(hub));

        Currency uaC = Currency.wrap(address(ua));
        pm.setClaimBalance(address(vault), uaC, 5);

        address deficitRecipient = makeAddr("deficitRecipient");
        uint256 requested = 9;
        uint256 expectedDeficit = requested - 5;

        // Deficit is paid in LCC tokens.
        lccErc20.mint(address(vault), expectedDeficit);

        vm.expectEmit(true, true, true, true, address(vault));
        emit MarketVault.SwapDeficit(
            PoolId.wrap(keccak256("pid")), address(lccErc20), deficitRecipient, expectedDeficit
        );

        uint256 amountToCancel = vault.exposed_cancelLCCWithDeficit(
            PoolId.wrap(keccak256("pid")), ILCC(address(lccErc20)), requested, deficitRecipient
        );

        assertEq(amountToCancel, 5);
        assertEq(hub.lastCancelLcc(), address(lccErc20));
        assertEq(hub.lastCancelFrom(), address(vault));
        assertEq(hub.lastCancelAmount(), 5);
        assertEq(hub.lastQueueLcc(), address(lccErc20));
        assertEq(hub.lastQueueRecipient(), deficitRecipient);
        assertEq(hub.lastQueueAmount(), expectedDeficit);
        assertEq(lccErc20.balanceOf(deficitRecipient), expectedDeficit);
    }

    function test_cancelLCCWithDeficit_doesNotTransferDeficitWhenRecipientIsZero() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,, MockLCC lccErc20,, MockERC20 ua) =
            _deployVaultWithHub(address(hub));

        Currency uaC = Currency.wrap(address(ua));
        pm.setClaimBalance(address(vault), uaC, 2);

        uint256 requested = 5;
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "MarketVault: deficit requires recipient")
        );
        vault.exposed_cancelLCCWithDeficit(
            PoolId.wrap(keccak256("pid2")), ILCC(address(lccErc20)), requested, address(0)
        );
    }

    function test_cancelLCCWithDeficit_whenFullyAvailable_doesNotQueueOrTransferDeficit() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,, MockLCC lccErc20,, MockERC20 ua) =
            _deployVaultWithHub(address(hub));

        Currency uaC = Currency.wrap(address(ua));
        uint256 requested = 5;
        address recipient = makeAddr("no_deficit_recipient");
        pm.setClaimBalance(address(vault), uaC, requested);

        uint256 amountToCancel = vault.exposed_cancelLCCWithDeficit(
            PoolId.wrap(keccak256("pid3")), ILCC(address(lccErc20)), requested, recipient
        );

        assertEq(amountToCancel, requested);
        assertEq(hub.lastCancelAmount(), requested);
        assertEq(hub.queueCalls(), 0);
        assertEq(lccErc20.balanceOf(recipient), 0);
    }

    function test_cancelLCCWithDeficit_zeroRecipientAllowedWhenNoDeficit() public {
        MockLiquidityHub_Min hub = new MockLiquidityHub_Min();
        (MarketVaultUnitHarness vault, MockPoolManager_Min pm,, MockLCC lccErc20,, MockERC20 ua) =
            _deployVaultWithHub(address(hub));

        Currency uaC = Currency.wrap(address(ua));
        uint256 requested = 3;
        pm.setClaimBalance(address(vault), uaC, requested);

        uint256 amountToCancel = vault.exposed_cancelLCCWithDeficit(
            PoolId.wrap(keccak256("pid4")), ILCC(address(lccErc20)), requested, address(0)
        );

        assertEq(amountToCancel, requested);
        assertEq(hub.lastCancelAmount(), requested);
        assertEq(hub.queueCalls(), 0);
    }
}
