// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {CanonicalTestFactory, MockLiquidityHubCV, MockPoolManagerCV} from "./base/CanonicalVaultTestFixtures.sol";
import {CanonicalVault} from "../src/CanonicalVault.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {VaultSettlementIntent} from "../src/types/VTS.sol";

import {MockERC20} from "./_mocks/MockERC20.sol";
import {MockLCC} from "./_mocks/MockLCC.sol";

/// @dev Hub that attempts to re-enter `CanonicalVault.modifyLiquidities` when receiving native ETH from the vault.
contract MockLiquidityHubReentrant is MockLiquidityHubCV {
    CanonicalVault internal _vault;
    bytes32 internal _marketId;
    Currency internal _currency0;
    Currency internal _currency1;
    address internal _lcc0;
    address internal _lcc1;
    bool internal _useSettlementIntentOverload;
    bool internal _armed;

    function armReentry(
        CanonicalVault vault_,
        bytes32 marketId_,
        Currency currency0_,
        Currency currency1_,
        address lcc0_,
        address lcc1_,
        bool useSettlementIntentOverload
    ) external {
        _vault = vault_;
        _marketId = marketId_;
        _currency0 = currency0_;
        _currency1 = currency1_;
        _lcc0 = lcc0_;
        _lcc1 = lcc1_;
        _useSettlementIntentOverload = useSettlementIntentOverload;
        _armed = true;
    }

    function disarm() external {
        _armed = false;
    }

    receive() external payable override {
        if (!_armed) return;
        _armed = false;
        if (_useSettlementIntentOverload) {
            VaultSettlementIntent memory vi = VaultSettlementIntent({
                requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
            });
            _vault.modifyLiquidities(_marketId, _currency0, _currency1, _lcc0, _lcc1, vi, address(this));
        } else {
            _vault.modifyLiquidities(
                _marketId, _currency0, _currency1, _lcc0, _lcc1, toBalanceDelta(1, 0), address(this)
            );
        }
    }
}

/// @notice Mutation-hardening regressions for `CanonicalVault` (see reports/canonical-vault-mutationtestresultsready).
contract CanonicalVaultMutationHardeningTest is Test {
    CanonicalTestFactory internal factory;
    MockPoolManagerCV internal pm;
    MockLiquidityHubCV internal hub;
    CanonicalVault internal vault;
    bytes32 internal constant MARKET_ID = keccak256("canonical-mutation-market");
    address internal facade = makeAddr("facadeMutation");

    function setUp() public {
        factory = new CanonicalTestFactory();
        pm = new MockPoolManagerCV();
        hub = new MockLiquidityHubCV();
        vault = new CanonicalVault(address(pm), address(hub), address(factory));
        factory.configure(address(hub), address(vault), makeAddr("vts"));
    }

    /// @dev Registers a market with `underlying0 < underlying1` and `lcc0 < lcc1`.
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
        revert("CanonicalVaultMutationHardeningTest: could not align lcc address order");
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
        revert("CanonicalVaultMutationHardeningTest: could not align native erc market");
    }

    function test_mutation_onlyMarketFacade_strangerDenied_allEntrypoints() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address stranger = makeAddr("strangerFacade");

        vm.startPrank(stranger);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), toBalanceDelta(1, 0));

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.dryModifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            VaultSettlementIntent({
                requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
            })
        );

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.modifyLiquidities(
            MARKET_ID, Currency.wrap(u0), Currency.wrap(u1), address(l0), address(l1), toBalanceDelta(1, 0), stranger
        );

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            VaultSettlementIntent({
                requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
            }),
            stranger
        );

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleObligations(MARKET_ID, address(l0), address(l1));

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleObligationsForLCC(MARKET_ID, address(l0));

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleUnderlyingToVaultFromHub(MARKET_ID, address(l0), 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.cancelLCCWithDeficit(MARKET_ID, address(l0), 0, address(0));

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.takeUnderlyingClaims(MARKET_ID, Currency.wrap(u0), 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.settleUnderlyingFromClaims(MARKET_ID, Currency.wrap(u0), 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.issueAndSettleLcc(MARKET_ID, address(l0), 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.takeLccFromPoolManager(MARKET_ID, address(l0), 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        vault.decreaseLiquidityReserve(MARKET_ID, Currency.wrap(u0), 1);

        vm.stopPrank();
    }

    function test_mutation_modifyLiquidities_revertsOnHubEthReentry_balanceDeltaOverload() public {
        _runHubEthReentryTest(false);
    }

    function test_mutation_modifyLiquidities_revertsOnHubEthReentry_settlementIntentOverload() public {
        _runHubEthReentryTest(true);
    }

    function _runHubEthReentryTest(bool useSettlementIntentOverload) internal {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockLiquidityHubReentrant hubRe = new MockLiquidityHubReentrant();
        CanonicalTestFactory f = new CanonicalTestFactory();
        MockPoolManagerCV p = new MockPoolManagerCV();
        CanonicalVault v = new CanonicalVault(address(p), address(hubRe), address(f));
        f.configure(address(hubRe), address(v), makeAddr("vts"));

        (MockLCC lNat, MockLCC lErc,,) = _deployRegisteredNativeErcMarketWithFactory(f, address(v), ua);

        hubRe.armReentry(
            v,
            MARKET_ID,
            Currency.wrap(address(0)),
            Currency.wrap(address(ua)),
            address(lNat),
            address(lErc),
            useSettlementIntentOverload
        );

        vm.prank(facade);
        v.increaseLiquidityReserve(MARKET_ID, Currency.wrap(address(0)), 3);
        p.setClaimBalance(address(v), Currency.wrap(address(0)), 3);
        vm.deal(address(p), 3);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "Native transfer to LiquidityHub failed")
        );
        vm.prank(facade);
        if (useSettlementIntentOverload) {
            VaultSettlementIntent memory vi = VaultSettlementIntent({
                requestedDelta: toBalanceDelta(3, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
            });
            v.modifyLiquidities(
                MARKET_ID,
                Currency.wrap(address(0)),
                Currency.wrap(address(ua)),
                address(lNat),
                address(lErc),
                vi,
                address(hubRe)
            );
        } else {
            v.modifyLiquidities(
                MARKET_ID,
                Currency.wrap(address(0)),
                Currency.wrap(address(ua)),
                address(lNat),
                address(lErc),
                toBalanceDelta(3, 0),
                address(hubRe)
            );
        }
    }

    function _deployRegisteredNativeErcMarketWithFactory(CanonicalTestFactory f, address vaultAddr, MockERC20 erc)
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
                f.registerVaultMarket(address(vaultAddr), MARKET_ID, facade, address(lNat), address(lErc), u0, u1);
                f.setMarketFacade(MARKET_ID, facade, true);
                return (lNat, lErc, u0, u1);
            }
        }
        revert("native erc alignment");
    }

    function test_mutation_modifyLiquidities_settlementIntent_token1_decrementsReserveOnlySettledSlice() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);

        vm.prank(facade);
        vault.increaseLiquidityReserve(MARKET_ID, Currency.wrap(u1), 5);
        pm.setClaimBalance(address(vault), Currency.wrap(u1), 7);
        MockERC20(u1).mint(address(pm), 7);

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 10), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 2
        });

        vm.prank(facade);
        BalanceDelta used = vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            vi,
            makeAddr("recvMutationToken1")
        );

        assertEq(used.amount1(), 7);
        assertEq(vault.inMarketBalanceOf(MARKET_ID, Currency.wrap(u1)), 0);
    }

    function test_mutation_modifyLiquidities_negativeLeg0_settlesUnfundedQueueAfterDeposit() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address lccE0 = address(l0);

        hub.setTotalQueued(lccE0, 20);
        hub.setMarketReserve(lccE0, 0);

        uint256 dep = 100;
        MockERC20(u0).mint(address(vault), dep);

        vm.prank(facade);
        pm.setClaimBalance(address(vault), Currency.wrap(u0), 0);
        MockERC20(u0).mint(address(pm), dep);

        vm.prank(facade);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(-int128(int256(dep)), 0),
            makeAddr("recvNeg0")
        );

        assertEq(hub.confirmCalls(), 1);
        assertEq(hub.lastConfirmLcc(), lccE0);
        assertEq(hub.lastConfirmAmount(), 20);
    }

    function test_mutation_modifyLiquidities_negativeLeg1_settlesUnfundedQueueAfterDeposit() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0, MockLCC l1, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address lccE1 = address(l1);

        hub.setTotalQueued(lccE1, 15);
        hub.setMarketReserve(lccE1, 0);

        uint256 dep = 50;
        MockERC20(u1).mint(address(vault), dep);

        vm.prank(facade);
        MockERC20(u1).mint(address(pm), dep);

        vm.prank(facade);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            address(l1),
            toBalanceDelta(0, -int128(int256(dep))),
            makeAddr("recvNeg1")
        );

        assertEq(hub.confirmCalls(), 1);
        assertEq(hub.lastConfirmLcc(), lccE1);
        assertEq(hub.lastConfirmAmount(), 15);
    }

    function test_mutation_dryModifyLiquidities_revertsWhenOnlySecondUnderlyingWrong() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (,, address u0,) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        MockERC20 wrong = new MockERC20("W", "W", 18);

        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.dryModifyLiquidities(MARKET_ID, Currency.wrap(u0), Currency.wrap(address(wrong)), toBalanceDelta(1, 0));
    }

    function test_mutation_modifyLiquidities_revertsWhenOnlySecondLccWrong() public {
        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        (MockLCC l0,, address u0, address u1) = _deployRegisteredMarket(MARKET_ID, ua, ub);
        address foreignLcc = makeAddr("foreignLccSecondSlot");

        vm.prank(facade);
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.modifyLiquidities(
            MARKET_ID,
            Currency.wrap(u0),
            Currency.wrap(u1),
            address(l0),
            foreignLcc,
            toBalanceDelta(1, 0),
            makeAddr("recv")
        );
    }

    function test_mutation_registerMarket_emitsMarketRegistered() public {
        MockERC20 ua = new MockERC20("RA", "RA", 18);
        MockERC20 ub = new MockERC20("RB", "RB", 18);
        bytes32 mid = keccak256("emit-market");

        MockLCC l0;
        MockLCC l1;
        address u0 = address(ua);
        address u1 = address(ub);
        if (u0 > u1) (u0, u1) = (u1, u0);

        for (uint256 i = 0; i < 64; i++) {
            l0 = new MockLCC("EL0", "EL0", 18, u0);
            l1 = new MockLCC("EL1", "EL1", 18, u1);
            if (address(l0) < address(l1)) {
                vm.expectEmit(true, true, true, true, address(vault));
                emit CanonicalVault.MarketRegistered(mid, facade, address(l0), address(l1));
                factory.registerVaultMarket(address(vault), mid, facade, address(l0), address(l1), u0, u1);
                return;
            }
        }
        revert("align lcc for emit test");
    }
}
