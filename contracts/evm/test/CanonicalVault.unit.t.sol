// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

import {CanonicalVault} from "../src/CanonicalVault.sol";
import {ICanonicalVault} from "../src/interfaces/ICanonicalVault.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {VaultSettlementIntent} from "../src/types/VTS.sol";

import {MockERC20} from "./_mocks/MockERC20.sol";
import {MockLCC} from "./_mocks/MockLCC.sol";

/// @dev Minimal ERC6909 PoolManager mock for CanonicalVault custody paths.
contract MockPoolManagerCV is IERC6909Claims {
    mapping(address => mapping(uint256 => uint256)) internal _claimBalances;
    mapping(address => mapping(address => bool)) internal _operators;

    function setClaimBalance(address owner, Currency currency, uint256 amount) external {
        _claimBalances[owner][currency.toId()] = amount;
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _claimBalances[owner][id];
    }

    function allowance(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isOperator(address owner, address spender) external view returns (bool) {
        return _operators[owner][spender];
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256, uint256) external pure returns (bool) {
        return true;
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
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "eth take failed");
        } else {
            MockERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        _operators[msg.sender][operator] = approved;
        return true;
    }

    receive() external payable {}
}

/// @dev Hub mock aligned with archived MarketVault unit tests + `issue` for LCC paths.
contract MockLiquidityHubCV {
    mapping(address => uint256) internal _queued;
    mapping(address => uint256) internal _reserveDirect;
    mapping(address => uint256) internal _reserveMarket;
    address internal _nativeSettleLcc;

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

    function unfundedQueueOfUnderlying(address lcc) external view returns (uint256) {
        uint256 queued = _queued[lcc];
        uint256 reserve = _reserveMarket[lcc];
        return queued > reserve ? queued - reserve : 0;
    }

    function setReserve(address lcc, uint256 amount) external {
        _reserveDirect[lcc] = amount;
    }

    function setMarketReserve(address lcc, uint256 amount) external {
        _reserveMarket[lcc] = amount;
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

    function setNativeSettleLcc(address lcc) external {
        _nativeSettleLcc = lcc;
    }

    function prepareSettle(address lcc, uint256 amount) external {
        uint256 direct = _reserveDirect[lcc];
        if (amount > direct) {
            revert Errors.InsufficientLiquidityToSettle();
        }
        _reserveDirect[lcc] = direct - amount;
        if (lcc == _nativeSettleLcc) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "native settle transfer failed");
        }
    }

    function issue(address, address, uint256) external {}

    receive() external payable {}
}

contract MockLiquidityHubRejectEthCV {
    mapping(address => uint256) internal _queued;
    mapping(address => uint256) internal _reserveDirect;
    mapping(address => uint256) internal _reserveMarket;

    function setTotalQueued(address lcc, uint256 amount) external {
        _queued[lcc] = amount;
    }

    function unfundedQueueOfUnderlying(address lcc) external view returns (uint256) {
        uint256 queued = _queued[lcc];
        uint256 reserve = _reserveMarket[lcc];
        return queued > reserve ? queued - reserve : 0;
    }

    function setMarketReserve(address lcc, uint256 amount) external {
        _reserveMarket[lcc] = amount;
    }

    function setReserve(address lcc, uint256 amount) external {
        _reserveDirect[lcc] = amount;
    }

    function confirmTake(address, uint256, bool) external {}

    function cancel(address, address, uint256) external {}

    function queueForTransferRecipient(address, address, uint256) external {}

    function prepareSettle(address lcc, uint256 amount) external {
        uint256 direct = _reserveDirect[lcc];
        if (amount > direct) {
            revert Errors.InsufficientLiquidityToSettle();
        }
        _reserveDirect[lcc] = direct - amount;
    }

    function issue(address, address, uint256) external {}

    receive() external payable {
        revert("reject");
    }
}

/// @dev Factory whose address is `marketFactory` on CanonicalVault; can register markets and answer `isMarketFacade` / `bounds`.
contract CanonicalTestFactory {
    address public liquidityHubAddr;
    address public canonical;
    address public vtsAddr;
    mapping(address => bool) internal _bound;
    mapping(bytes32 => mapping(address => bool)) internal _facade;

    function configure(address hub, address can, address vtsAddress) external {
        liquidityHubAddr = hub;
        canonical = can;
        vtsAddr = vtsAddress;
    }

    function liquidityHub() external view returns (address) {
        return liquidityHubAddr;
    }

    function canonicalVault() external view returns (address) {
        return canonical;
    }

    function bounds(address a) external view returns (bool) {
        return _bound[a];
    }

    function setBound(address a, bool v) external {
        _bound[a] = v;
    }

    function isMarketFacade(bytes32 m, address f) external view returns (bool) {
        return _facade[m][f];
    }

    function setMarketFacade(bytes32 m, address f, bool ok) external {
        _facade[m][f] = ok;
    }

    function vts() external view returns (address) {
        return vtsAddr;
    }

    function registerVaultMarket(
        address vault,
        bytes32 marketId,
        address facade,
        address lcc0,
        address lcc1,
        address underlying0,
        address underlying1
    ) external {
        ICanonicalVault(vault).registerMarket(marketId, facade, lcc0, lcc1, underlying0, underlying1);
    }
}

/// @notice Hardened unit tests for CanonicalVault (custody engine). Ported from archived MarketVault.unit.t.sol patterns.
contract CanonicalVaultUnitTest is Test {
    receive() external payable {}

    CanonicalTestFactory internal factory;
    MockPoolManagerCV internal pm;
    MockLiquidityHubCV internal hub;
    CanonicalVault internal vault;
    bytes32 internal constant MARKET_ID = keccak256("canonical-unit-market");
    address internal facade = makeAddr("facade");

    function setUp() public {
        factory = new CanonicalTestFactory();
        pm = new MockPoolManagerCV();
        hub = new MockLiquidityHubCV();
        vault = new CanonicalVault(address(pm), address(hub), address(factory));
        factory.configure(address(hub), address(vault), makeAddr("vts"));
    }

    /// @dev Registers a market with `underlying0 < underlying1` and `lcc0 < lcc1`, and
    ///      `ILCC(lcc{i}).underlying() == underlying{i}` (required for delta0/delta1 ↔ LCC pairing in the vault).
    function _deployRegisteredMarket(bytes32 marketId, MockERC20 ua0, MockERC20 ua1)
        internal
        returns (MockLCC l0, MockLCC l1, address u0, address u1)
    {
        u0 = address(ua0);
        u1 = address(ua1);
        if (u0 > u1) (u0, u1) = (u1, u0);

        for (uint256 i = 0; i < 64; i++) {
            l0 = new MockLCC("L0", "L0", 18, u0);
            l1 = new MockLCC("L1", "L1", 18, u1);
            if (address(l0) < address(l1)) {
                factory.registerVaultMarket(address(vault), marketId, facade, address(l0), address(l1), u0, u1);
                factory.setMarketFacade(marketId, facade, true);
                return (l0, l1, u0, u1);
            }
        }
        revert("CanonicalVaultUnitTest: could not align lcc address order");
    }

    /// @dev Native (`underlying0`) + ERC20 pair with `lcc0 < lcc1` and `underlying0 < underlying1`.
    function _deployRegisteredNativeErcMarket(bytes32 marketId, MockERC20 erc)
        internal
        returns (MockLCC lNat, MockLCC lErc, address u0, address u1)
    {
        for (uint256 i = 0; i < 64; i++) {
            lNat = new MockLCC("LN", "LN", 18, address(0));
            lErc = new MockLCC("LE", "LE", 18, address(erc));
            u0 = address(0);
            u1 = address(erc);
            if (u0 > u1) (u0, u1) = (u1, u0);
            if (address(lNat) < address(lErc)) {
                factory.registerVaultMarket(address(vault), marketId, facade, address(lNat), address(lErc), u0, u1);
                factory.setMarketFacade(marketId, facade, true);
                return (lNat, lErc, u0, u1);
            }
        }
        revert("CanonicalVaultUnitTest: could not align native erc market");
    }

    function test_registerMarket_revertsWhenMarketIdZero() public {
        vm.expectRevert(
            abi.encodeWithSignature("InvariantViolated(string)", "CanonicalVault: zero marketId unsupported")
        );
        factory.registerVaultMarket(address(vault), bytes32(0), facade, address(1), address(2), address(3), address(4));
    }

    function test_registerMarket_revertsWhenFacadeOrLccZero() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        factory.registerVaultMarket(
            address(vault), keccak256("m2"), address(0), address(1), address(2), address(3), address(4)
        );
    }

    function test_registerMarket_revertsWhenDuplicate() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.expectRevert(
            abi.encodeWithSignature("InvariantViolated(string)", "CanonicalVault: market already registered")
        );
        factory.registerVaultMarket(address(vault), MARKET_ID, makeAddr("other"), address(l0), address(l1), u0, u1);
    }

    function test_registerMarket_revertsWhenNotFactory() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.registerMarket(MARKET_ID, facade, address(1), address(2), address(3), address(4));
    }

    function test_inMarketBalanceOf_revertsWhenMarketUnknown() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.inMarketBalanceOf(keccak256("unknown"), Currency.wrap(u0));
    }

    function test_onlyMarketFacade_revertsForNonFacadeCaller() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(makeAddr("notFacade"));
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 1);
    }

    function test_onlyMarketFacade_revertsWhenFactorySaysNotFacade() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        factory.setMarketFacade(MARKET_ID, facade, false);

        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 1);
    }

    function test_takeUnderlyingClaims_and_settleUnderlyingFromClaims_zeroAmountNoop() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.startPrank(facade);
        vault.takeUnderlyingClaims(MARKET_ID, Currency.wrap(u0), 0);
        vault.settleUnderlyingFromClaims(MARKET_ID, Currency.wrap(u0), 0);
        vm.stopPrank();
    }

    function test_settleUnderlyingFromClaims_revertsWhenReserveInsufficient() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        vault.settleUnderlyingFromClaims(MARKET_ID, Currency.wrap(u0), 1);
    }

    function test_cancelLCCWithDeficit_matrix() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address lccE = address(l0);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 5);

        address recipient = makeAddr("deficitRecipient");
        vm.prank(facade);
        MockLCC(lccE).mint(address(vault), 4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CanonicalVault.SwapDeficit(PoolId.wrap(MARKET_ID), lccE, recipient, 4);

        vm.prank(facade);
        uint256 toCancel = vault.cancelLCCWithDeficit(MARKET_ID, lccE, 9, recipient);
        assertEq(toCancel, 5);
        assertEq(hub.lastCancelAmount(), 5);
        assertEq(hub.queueCalls(), 1);
        assertEq(hub.lastQueueAmount(), 4);

        vm.prank(facade);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "MarketVault: deficit requires recipient")
        );
        vault.cancelLCCWithDeficit(MARKET_ID, lccE, 9, address(0));

        vm.prank(facade);
        uint256 full = vault.cancelLCCWithDeficit(MARKET_ID, lccE, 3, address(0));
        assertEq(full, 3);
    }

    function test_settleObligationsForLCC_unfundedTail() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0,,,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address lccE = address(l0);
        address uaL0 = l0.underlying();

        hub.setTotalQueued(lccE, 20);
        hub.setMarketReserve(lccE, 7);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(uaL0), 100);
        pm.setClaimBalance(address(vault), Currency.wrap(uaL0), 100);
        MockERC20(uaL0).mint(address(pm), 100);

        vm.prank(facade);
        vault.settleObligationsForLCC(MARKET_ID, lccE);

        assertEq(hub.confirmCalls(), 1);
        assertEq(hub.lastConfirmAmount(), 13);
    }

    function test_settleObligationsForLCC_earlyReturnNoQueue() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0,,,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        hub.setTotalQueued(address(l0), 0);

        vm.prank(facade);
        vault.settleObligationsForLCC(MARKET_ID, address(l0));
        assertEq(hub.confirmCalls(), 0);
    }

    /// @dev Wrapper settles both LCC lanes in one call (mutation target vs single-LCC entrypoint).
    function test_settleObligations_bothLCCs_confirmTwice() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1,,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address lccE0 = address(l0);
        address lccE1 = address(l1);
        address uaL0 = l0.underlying();
        address uaL1 = l1.underlying();

        hub.setTotalQueued(lccE0, 12);
        hub.setMarketReserve(lccE0, 0);
        hub.setTotalQueued(lccE1, 7);
        hub.setMarketReserve(lccE1, 0);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(uaL0), 100);
        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(uaL1), 100);
        pm.setClaimBalance(address(vault), Currency.wrap(uaL0), 100);
        pm.setClaimBalance(address(vault), Currency.wrap(uaL1), 100);
        MockERC20(uaL0).mint(address(pm), 100);
        MockERC20(uaL1).mint(address(pm), 100);

        vm.prank(facade);
        vault.settleObligations(MARKET_ID, lccE0, lccE1);

        assertEq(hub.confirmCalls(), 2);
    }

    function test_settleUnderlyingToVaultFromHub_nativePath() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        (MockLCC lNat,,,) = _deployRegisteredNativeErcMarket(MARKET_ID, ua);

        hub.setNativeSettleLcc(address(lNat));
        hub.setReserve(address(lNat), 5);
        vm.deal(address(hub), 5);

        factory.setBound(address(hub), true);

        vm.prank(facade);
        vault.settleUnderlyingToVaultFromHub(MARKET_ID, address(lNat), 5);

        assertEq(pm.balanceOf(address(vault), Currency.wrap(address(0)).toId()), 5);
    }

    /// @dev ERC20 LCC: hub is the ERC20 `transferFrom` payer; reserve decremented in `prepareSettle`, claims land on the vault.
    function test_settleUnderlyingToVaultFromHub_erc20Path() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        uint256 amt = 8;
        hub.setReserve(address(l0), amt);
        MockERC20(u0).mint(address(hub), amt);
        // `Currency.settle` pulls with `transferFrom(payer, poolManager, …)` where `msg.sender` is the vault.
        vm.prank(address(hub));
        MockERC20(u0).approve(address(vault), type(uint256).max);

        vm.prank(facade);
        vault.settleUnderlyingToVaultFromHub(MARKET_ID, address(l0), amt);

        assertEq(pm.balanceOf(address(vault), Currency.wrap(u0).toId()), amt);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), amt);
    }

    function test_settleUnderlyingToVaultFromHub_revertsInsufficientReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        (MockLCC lNat,,,) = _deployRegisteredNativeErcMarket(MARKET_ID, ua);
        hub.setNativeSettleLcc(address(lNat));
        hub.setReserve(address(lNat), 4);
        vm.deal(address(hub), 4);
        factory.setBound(address(hub), true);

        vm.prank(facade);
        vm.expectRevert(Errors.InsufficientLiquidityToSettle.selector);
        vault.settleUnderlyingToVaultFromHub(MARKET_ID, address(lNat), 9);
    }

    function test_receive_acceptsPoolManagerLiquidityHubAndBound() public {
        MockLiquidityHubCV h = new MockLiquidityHubCV();
        CanonicalTestFactory f = new CanonicalTestFactory();
        MockPoolManagerCV p = new MockPoolManagerCV();
        CanonicalVault v = new CanonicalVault(address(p), address(h), address(f));
        f.configure(address(h), address(v), makeAddr("vts"));

        vm.deal(address(p), 1);
        vm.deal(address(h), 1);
        vm.deal(address(v), 0);
        vm.prank(address(p));
        (bool okPm,) = address(v).call{value: 1}("");
        assertTrue(okPm);

        vm.deal(address(h), 1);
        vm.prank(address(h));
        (bool okHub,) = address(v).call{value: 1}("");
        assertTrue(okHub);

        f.setBound(address(this), true);
        vm.deal(address(this), 1);
        (bool okB,) = address(v).call{value: 1}("");
        assertTrue(okB);
    }

    function test_receive_revertsUnknownSender() public {
        MockLiquidityHubCV h = new MockLiquidityHubCV();
        CanonicalTestFactory f = new CanonicalTestFactory();
        MockPoolManagerCV p = new MockPoolManagerCV();
        CanonicalVault v = new CanonicalVault(address(p), address(h), address(f));
        f.configure(address(h), address(v), makeAddr("vts"));

        vm.deal(makeAddr("stranger"), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.InvalidEthSender.selector);
        (bool ok,) = address(v).call{value: 1 wei}("");
        ok;
    }

    function test_dryModifyLiquidities_clampsToReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 5);

        vm.prank(facade);
        BalanceDelta d =
            vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), toBalanceDelta(9, 0));
        assertEq(d.amount0(), 5);
    }

    function test_modifyLiquidities_confirmTakeWhenRecipientIsHub() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 6);
        pm.setClaimBalance(address(vault), Currency.wrap(u0), 6);
        MockERC20(u0).mint(address(pm), 6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CanonicalVault.LiquidityTakenFromVault(MARKET_ID, address(hub), u0, 6);

        vm.prank(facade);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(6, 0),
            address(hub)
        );

        assertEq(hub.lastConfirmLcc(), address(l0));
        assertEq(hub.lastConfirmAmount(), 6);
    }

    /// @dev Leg1 mirror of `confirmTakeWhenRecipientIsHub` (token0-only positive leg).
    function test_modifyLiquidities_confirmTakeWhenRecipientIsHub_token1() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u1), 6);
        pm.setClaimBalance(address(vault), Currency.wrap(u1), 6);
        MockERC20(u1).mint(address(pm), 6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CanonicalVault.LiquidityTakenFromVault(MARKET_ID, address(hub), u1, 6);

        vm.prank(facade);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(0, 6),
            address(hub)
        );

        assertEq(hub.lastConfirmLcc(), address(l1));
        assertEq(hub.lastConfirmAmount(), 6);
    }

    function test_registerMarket_revertsWhenDuplicateFacade() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        _deployRegisteredMarket(MARKET_ID, ua, ub);

        bytes32 otherMarket = keccak256("other-market");
        MockERC20 uc = new MockERC20("C", "C", 18);
        MockERC20 ud = new MockERC20("D", "D", 18);
        address u2 = address(uc);
        address u3 = address(ud);
        if (u2 > u3) (u2, u3) = (u3, u2);

        for (uint256 i = 0; i < 64; i++) {
            MockLCC l2 = new MockLCC("L2", "L2", 18, u2);
            MockLCC l3 = new MockLCC("L3", "L3", 18, u3);
            if (address(l2) < address(l3)) {
                vm.expectRevert(
                    abi.encodeWithSignature("InvariantViolated(string)", "CanonicalVault: market already registered")
                );
                factory.registerVaultMarket(address(vault), otherMarket, facade, address(l2), address(l3), u2, u3);
                return;
            }
        }
        revert("align lcc for duplicate facade test");
    }

    function test_takeUnderlyingClaims_revertsWrongUnderlying() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        _deployRegisteredMarket(MARKET_ID, ua, ub);
        MockERC20 ux = new MockERC20("X", "X", 18);
        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.takeUnderlyingClaims(MARKET_ID, Currency.wrap(address(ux)), 1);
    }

    function test_settleUnderlyingFromClaims_revertsWrongUnderlying() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        _deployRegisteredMarket(MARKET_ID, ua, ub);
        MockERC20 ux = new MockERC20("X", "X", 18);
        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleUnderlyingFromClaims(MARKET_ID, Currency.wrap(address(ux)), 1);
    }

    function test_dryModifyLiquidities_reverts_swappedUnderlyingPair() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u1), Currency.wrap(u0), toBalanceDelta(1, 0));
    }

    function test_modifyLiquidities_reverts_wrongLccPairOrder() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l1),
            address(l0),
            toBalanceDelta(1, 0),
            makeAddr("recv")
        );
    }

    function test_dryModify_settlementIntent_creditBackedClampedToRequested() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(5, 0), creditBackedWithdrawal0: 99, creditBackedWithdrawal1: 0
        });
        vm.prank(facade);
        BalanceDelta d = vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), vi);
        assertEq(d.amount0(), 5);
    }

    function test_dryModify_settlementIntent_mixedCreditAndReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 5);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(10, 0), creditBackedWithdrawal0: 2, creditBackedWithdrawal1: 0
        });
        vm.prank(facade);
        BalanceDelta d = vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), vi);
        assertEq(d.amount0(), 7);
    }

    /// @dev Negative (and zero) legs skip the reserve/credit clamp; positive legs are capped by reserve.
    function test_dryModify_settlementIntent_negativeLegs_passthrough() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(-4, -2), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(facade);
        BalanceDelta d = vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), vi);
        assertEq(d.amount0(), -4);
        assertEq(d.amount1(), -2);
    }

    function test_settleObligationsForLCC_unfundedButNoVaultReserve_exitsWithoutConfirm() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0,,,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        hub.setTotalQueued(address(l0), 100);
        hub.setMarketReserve(address(l0), 0);

        vm.prank(facade);
        vault.settleObligationsForLCC(MARKET_ID, address(l0));
        assertEq(hub.confirmCalls(), 0);
    }

    function test_settleUnderlyingToVaultFromHub_zeroAmount_noop() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        (MockLCC lNat,,,) = _deployRegisteredNativeErcMarket(MARKET_ID, ua);
        vm.prank(facade);
        vault.settleUnderlyingToVaultFromHub(MARKET_ID, address(lNat), 0);
    }

    function test_inMarketBalanceOf_returnsIncreasedReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 42);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), 42);
    }

    /// @dev `takeUnderlyingClaims` mints ERC6909 claims to the vault and mirrors `marketLiquidityReserves`; `settleUnderlyingFromClaims` burns and decrements.
    function test_takeUnderlyingClaims_then_settleUnderlyingFromClaims_updatesReservesAndClaims() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        uint256 amt = 33;
        vm.startPrank(facade);
        vault.takeUnderlyingClaims(MARKET_ID, Currency.wrap(u0), amt);
        vm.stopPrank();

        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), amt);
        assertEq(pm.balanceOf(address(vault), Currency.wrap(u0).toId()), amt);
        assertEq(vault.totalUnderlyingReserves(u0), amt);

        vm.startPrank(facade);
        vault.settleUnderlyingFromClaims(MARKET_ID, Currency.wrap(u0), amt);
        vm.stopPrank();

        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), 0);
        assertEq(pm.balanceOf(address(vault), Currency.wrap(u0).toId()), 0);
        assertEq(vault.totalUnderlyingReserves(u0), 0);
    }

    /// @dev Negative requested leg0 executes `_settleUnderlyingToVaultFromSender` (ERC20 from vault) and increases durable reserve; no unfunded hub queue on that LCC.
    function test_modifyLiquidities_negativeLeg0_depositsUnderlyingAndIncrementsReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        hub.setTotalQueued(address(l0), 0);
        hub.setMarketReserve(address(l0), 0);

        int128 dep = 11;
        MockERC20(u0).mint(address(vault), 11);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CanonicalVault.LiquidityAddedToVault(MARKET_ID, address(vault), u0, 11);

        vm.prank(facade);
        BalanceDelta used = vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(-dep, 0),
            makeAddr("recipientNeg")
        );

        assertEq(used.amount0(), -dep);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), 11);
        assertEq(pm.balanceOf(address(vault), Currency.wrap(u0).toId()), 11);
    }

    /// @dev Leg1 mirror: negative `amount1` deposits underlying1 from the vault and increments reserve.
    function test_modifyLiquidities_negativeLeg1_depositsUnderlyingAndIncrementsReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        hub.setTotalQueued(address(l1), 0);
        hub.setMarketReserve(address(l1), 0);

        int128 dep = 9;
        MockERC20(u1).mint(address(vault), 9);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CanonicalVault.LiquidityAddedToVault(MARKET_ID, address(vault), u1, 9);

        vm.prank(facade);
        BalanceDelta used = vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(0, -dep),
            makeAddr("recipientNeg1")
        );

        assertEq(used.amount1(), -dep);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u1)), 9);
        assertEq(pm.balanceOf(address(vault), Currency.wrap(u1).toId()), 9);
    }

    /// @dev Mixed sign: deposit token0 from vault (negative leg0) while withdrawing token1 to a recipient (positive leg1).
    function test_modifyLiquidities_mixedSign_negativeToken0_positiveToken1() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        hub.setTotalQueued(address(l0), 0);
        hub.setMarketReserve(address(l0), 0);
        hub.setTotalQueued(address(l1), 0);
        hub.setMarketReserve(address(l1), 0);

        MockERC20(u0).mint(address(vault), 3);
        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u1), 5);
        pm.setClaimBalance(address(vault), Currency.wrap(u1), 5);
        MockERC20(u1).mint(address(pm), 5);

        address recv = makeAddr("recvMixed");

        vm.expectEmit(true, false, false, true, address(vault));
        emit CanonicalVault.LiquidityAddedToVault(MARKET_ID, address(vault), u0, 3);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CanonicalVault.LiquidityTakenFromVault(MARKET_ID, recv, u1, 5);

        vm.prank(facade);
        BalanceDelta used = vault.modifyLiquidities(
            MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), address(l0), address(l1), toBalanceDelta(-3, 5), recv
        );

        assertEq(used.amount0(), -3);
        assertEq(used.amount1(), 5);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), 3);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u1)), 0);
    }

    /// @dev `_assertLccConfigured` rejects addresses that are not the registered LCC pair.
    function test_foreignLcc_revertsOnHubSettle_obligation_and_cancel() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        _deployRegisteredMarket(MARKET_ID, ua, ub);
        address foreign = makeAddr("foreignLcc");

        vm.startPrank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleUnderlyingToVaultFromHub(MARKET_ID, foreign, 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleObligationsForLCC(MARKET_ID, foreign);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.cancelLCCWithDeficit(MARKET_ID, foreign, 0, address(0));

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.issueAndSettleLcc(MARKET_ID, foreign, 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.takeLccFromPoolManager(MARKET_ID, foreign, 1);
        vm.stopPrank();
    }

    function test_constructor_revertsWhenLiquidityHubZero() public {
        MockPoolManagerCV p = new MockPoolManagerCV();
        CanonicalTestFactory f = new CanonicalTestFactory();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new CanonicalVault(address(p), address(0), address(f));
    }

    function test_constructor_revertsWhenMarketFactoryZero() public {
        MockPoolManagerCV p = new MockPoolManagerCV();
        MockLiquidityHubCV h = new MockLiquidityHubCV();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new CanonicalVault(address(p), address(h), address(0));
    }

    /// @dev State-changing `modifyLiquidities` with `VaultSettlementIntent` (not only `dryModify`).
    function test_modifyLiquidities_withSettlementIntent_mixedCreditAndReserve_decrementsReserveOnlySettledSlice()
        public
    {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 5);
        pm.setClaimBalance(address(vault), Currency.wrap(u0), 7);
        MockERC20(u0).mint(address(pm), 7);

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(10, 0), creditBackedWithdrawal0: 2, creditBackedWithdrawal1: 0
        });

        vm.prank(facade);
        BalanceDelta used = vault.modifyLiquidities(
            MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), address(l0), address(l1), vi, makeAddr("recvIntent")
        );

        assertEq(used.amount0(), 7);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), 0);
    }

    function test_dryModifyLiquidities_clampsLeg1ToReserve() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u1), 5);

        vm.prank(facade);
        BalanceDelta d =
            vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), toBalanceDelta(0, 9));
        assertEq(d.amount1(), 5);
    }

    function test_dryModify_settlementIntent_creditBackedClampedToRequested_token1() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 5), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 99
        });
        vm.prank(facade);
        BalanceDelta d = vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), vi);
        assertEq(d.amount1(), 5);
    }

    function test_dryModify_settlementIntent_mixedCreditAndReserve_token1() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u1), 5);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 10), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 2
        });
        vm.prank(facade);
        BalanceDelta d = vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), vi);
        assertEq(d.amount1(), 7);
    }

    function test_modifyLiquidities_positiveLeg_revertsWhenPoolManagerClaimsInsufficient() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 10);

        vm.prank(facade);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(1, 0),
            makeAddr("recvPmShort")
        );
    }

    function test_modifyLiquidities_negativeLeg0_revertsWhenVaultUnderlyingBalanceInsufficient() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        hub.setTotalQueued(address(l0), 0);
        hub.setMarketReserve(address(l0), 0);

        vm.prank(facade);
        vm.expectRevert(Errors.InsufficientLiquidityToSettle.selector);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(-1, 0),
            makeAddr("recvNeg")
        );
    }

    function test_modifyLiquidities_confirmTakeWhenRecipientIsHub_bothLegsPositive() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 4);
        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u1), 5);
        pm.setClaimBalance(address(vault), Currency.wrap(u0), 4);
        pm.setClaimBalance(address(vault), Currency.wrap(u1), 5);
        MockERC20(u0).mint(address(pm), 4);
        MockERC20(u1).mint(address(pm), 5);

        vm.prank(facade);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(4, 5),
            address(hub)
        );

        assertEq(hub.confirmCalls(), 2);
    }

    function test_decreaseLiquidityReserve_zeroAmount_noop() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 100);

        vm.prank(facade);
        vault.decreaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 0);

        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u0)), 100);
    }

    function test_decreaseLiquidityReserve_revertsWhenReserveInsufficient() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 1);

        vm.prank(facade);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        vault.decreaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 2);
    }

    function test_decreaseLiquidityReserve_revertsWrongUnderlying() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        _deployRegisteredMarket(MARKET_ID, ua, ub);
        MockERC20 ux = new MockERC20("X", "X", 18);

        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.decreaseLiquidityReserve(MARKET_ID, Currency.wrap(address(ux)), 1);
    }

    function test_inMarketBalanceOf_revertsWrongUnderlying() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        _deployRegisteredMarket(MARKET_ID, ua, ub);
        MockERC20 ux = new MockERC20("X", "X", 18);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(address(ux)));
    }

    function _registerNativeErcAligned(CanonicalTestFactory f, address vaultAddr, MockERC20 erc)
        internal
        returns (address lccLo, address lccHi, Currency cu0, Currency cu1)
    {
        for (uint256 i = 0; i < 64; i++) {
            MockLCC lNat = new MockLCC("LN", "LN", 18, address(0));
            MockLCC lErc = new MockLCC("LE", "LE", 18, address(erc));
            address u0 = address(0);
            address u1 = address(erc);
            if (u0 > u1) (u0, u1) = (u1, u0);
            if (address(lNat) < address(lErc)) {
                lccLo = address(lNat);
                lccHi = address(lErc);
                f.registerVaultMarket(vaultAddr, MARKET_ID, facade, lccLo, lccHi, u0, u1);
                f.setMarketFacade(MARKET_ID, facade, true);
                cu0 = Currency.wrap(u0);
                cu1 = Currency.wrap(u1);
                return (lccLo, lccHi, cu0, cu1);
            }
        }
        revert("native erc alignment");
    }

    function _deployVaultWithRejectingHub()
        internal
        returns (
            CanonicalVault v,
            MockPoolManagerCV p,
            address hRej,
            address lccLo,
            address lccHi,
            Currency cu0,
            Currency cu1
        )
    {
        MockLiquidityHubRejectEthCV hubRej = new MockLiquidityHubRejectEthCV();
        hRej = address(hubRej);
        CanonicalTestFactory f = new CanonicalTestFactory();
        p = new MockPoolManagerCV();
        v = new CanonicalVault(address(p), hRej, address(f));
        f.configure(hRej, address(v), makeAddr("vts"));

        MockERC20 ua = new MockERC20("A", "A", 18);
        (lccLo, lccHi, cu0, cu1) = _registerNativeErcAligned(f, address(v), ua);
    }

    function test_nativeToHubTransfer_revertsWhenHubRejectsEth() public {
        (
            CanonicalVault v,
            MockPoolManagerCV p,
            address hRej,
            address lccLo,
            address lccHi,
            Currency cu0,
            Currency cu1
        ) = _deployVaultWithRejectingHub();

        vm.prank(facade);
        v.increaseLiquidityReserve(MARKET_ID, Currency.wrap(address(0)), 3);
        p.setClaimBalance(address(v), Currency.wrap(address(0)), 3);
        vm.deal(address(p), 3);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "Native transfer to LiquidityHub failed")
        );
        vm.prank(facade);
        v.modifyLiquidities(MARKET_ID, cu0, cu1, lccLo, lccHi, toBalanceDelta(3, 0), hRej);
    }
}
