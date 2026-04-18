// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MarketVaultFacade} from "../../src/modules/MarketVaultFacade.sol";
import {ICanonicalVault} from "../../src/interfaces/ICanonicalVault.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {IVTSOrchestrator} from "../../src/interfaces/IVTSOrchestrator.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {VaultSettlementIntent} from "../../src/types/VTS.sol";

import {MockERC20} from "../_mocks/MockERC20.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";

/// @dev Narrow interfaces so `abi.encodeCall` can pick a single `dryModifyLiquidities` overload.
interface ICanonicalDryBd {
    function dryModifyLiquidities(bytes32, Currency, Currency, BalanceDelta) external view returns (BalanceDelta);
}

interface ICanonicalDryIntent {
    function dryModifyLiquidities(bytes32, Currency, Currency, VaultSettlementIntent calldata)
        external
        view
        returns (BalanceDelta);
}

interface ICanonicalInMarket {
    function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256);
}

interface ICanonicalReserveInc {
    function increaseLiquidityReserve(bytes32 marketId, Currency currency, uint256 amount) external;
}

interface ICanonicalReserveDec {
    function decreaseLiquidityReserve(bytes32 marketId, Currency currency, uint256 amount) external;
}

/// @dev Narrow `IMarketVault` surfaces for `abi.encodeCall` overload resolution in re-entry tests.
interface IMarketVaultModifyBd {
    function modifyLiquidities(BalanceDelta balanceDelta) external;
}

interface IMarketVaultModifyIntent {
    function modifyLiquidities(VaultSettlementIntent calldata settlementIntent) external;
}

interface IMarketVaultTryBd {
    function tryModifyLiquidities(BalanceDelta balanceDelta) external returns (BalanceDelta);
}

interface IMarketVaultTryIntent {
    function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent) external returns (BalanceDelta);
}

interface IMarketVaultTryRecipBd {
    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address recipient)
        external
        returns (BalanceDelta);
}

interface IMarketVaultTryRecipIntent {
    function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address recipient)
        external
        returns (BalanceDelta);
}

/// @notice Minimal factory surface for `MarketVaultFacade` unit tests.
contract FacadeUnitTestFactory {
    address public canonicalVaultAddr;
    address public vtsAddr;
    mapping(address => bool) public bounds;

    function setCanonicalVault(address a) external {
        canonicalVaultAddr = a;
    }

    function setVts(address a) external {
        vtsAddr = a;
    }

    function setBound(address a, bool ok) external {
        bounds[a] = ok;
    }

    function canonicalVault() external view returns (address) {
        return canonicalVaultAddr;
    }

    function vts() external view returns (IVTSOrchestrator) {
        return IVTSOrchestrator(vtsAddr);
    }
}

/// @notice Canonical stub: `modifyLiquidities` records forwarded args (routing regressions). `dryModify` is view-only.
contract MockCanonicalForFacade is ICanonicalVault {
    BalanceDelta internal _modifyReturn;
    BalanceDelta internal _dryReturn;
    bool public echoModify;
    uint256 internal _cancelReturn;

    uint8 public lastModifyKind;
    bytes32 public lastModifyMarketId;
    Currency public lastModifyC0;
    Currency public lastModifyC1;
    address public lastModifyLcc0;
    address public lastModifyLcc1;
    address public lastModifyRecipient;
    BalanceDelta public lastModifyBalanceDelta;
    VaultSettlementIntent public lastModifyIntent;

    function setModifyReturn(BalanceDelta d) external {
        _modifyReturn = d;
    }

    function setDryReturn(BalanceDelta d) external {
        _dryReturn = d;
    }

    function setEchoModify(bool v) external {
        echoModify = v;
    }

    function setCancelReturn(uint256 v) external {
        _cancelReturn = v;
    }

    function marketFactory() external view returns (address) {
        return address(this);
    }

    function registerMarket(bytes32, address, address, address, address, address) external pure {}

    function inMarketBalanceOf(bytes32, Currency) external pure returns (uint256) {
        return 0;
    }

    function dryModifyLiquidities(bytes32, Currency, Currency, BalanceDelta) external view returns (BalanceDelta) {
        return _dryReturn;
    }

    function dryModifyLiquidities(bytes32, Currency, Currency, VaultSettlementIntent calldata)
        external
        view
        returns (BalanceDelta)
    {
        return _dryReturn;
    }

    function modifyLiquidities(
        bytes32 mid,
        Currency c0,
        Currency c1,
        address l0,
        address l1,
        BalanceDelta bd,
        address recipient
    ) external virtual returns (BalanceDelta) {
        _hookBeforeModifyBalanceDelta();
        lastModifyKind = 1;
        lastModifyMarketId = mid;
        lastModifyC0 = c0;
        lastModifyC1 = c1;
        lastModifyLcc0 = l0;
        lastModifyLcc1 = l1;
        lastModifyRecipient = recipient;
        lastModifyBalanceDelta = bd;
        if (echoModify) {
            return bd;
        }
        return _modifyReturn;
    }

    function modifyLiquidities(
        bytes32 mid,
        Currency c0,
        Currency c1,
        address l0,
        address l1,
        VaultSettlementIntent calldata vi,
        address recipient
    ) external virtual returns (BalanceDelta) {
        _hookBeforeModifyIntent();
        lastModifyKind = 2;
        lastModifyMarketId = mid;
        lastModifyC0 = c0;
        lastModifyC1 = c1;
        lastModifyLcc0 = l0;
        lastModifyLcc1 = l1;
        lastModifyRecipient = recipient;
        lastModifyIntent = vi;
        if (echoModify) {
            return vi.requestedDelta;
        }
        return _modifyReturn;
    }

    function settleObligations(bytes32, address, address) external pure {}

    function settleObligationsForLCC(bytes32, address) external pure {}

    function settleUnderlyingToVaultFromHub(bytes32, address, uint256) external pure {}

    function cancelLCCWithDeficit(bytes32, address, uint256, address) external view returns (uint256) {
        return _cancelReturn;
    }

    function takeUnderlyingClaims(bytes32, Currency, uint256) external pure {}

    function settleUnderlyingFromClaims(bytes32, Currency, uint256) external pure {}

    function issueAndSettleLcc(bytes32, address, uint256) external pure {}

    function takeLccFromPoolManager(bytes32, address, uint256) external pure {}

    function increaseLiquidityReserve(bytes32, Currency, uint256) external pure {}

    function decreaseLiquidityReserve(bytes32, Currency, uint256) external pure {}

    function _hookBeforeModifyBalanceDelta() internal virtual {}

    function _hookBeforeModifyIntent() internal virtual {}
}

/// @notice Canonical stub that optionally re-enters the facade during `modifyLiquidities` to kill `nonReentrant` mutants.
contract ReentrantCanonicalForFacade is MockCanonicalForFacade {
    error Reentered();

    uint256 internal _reDepth;
    address internal _reFacade;
    uint8 internal _reMode;
    BalanceDelta internal _reBd;
    VaultSettlementIntent internal _reVi;
    address internal _reRecipient;

    uint8 public constant RM_MODIFY_BD = 1;
    uint8 public constant RM_TRY_BD = 2;
    uint8 public constant RM_TRY_RECIP_BD = 3;
    uint8 public constant RM_MODIFY_INTENT = 4;
    uint8 public constant RM_TRY_INTENT = 5;
    uint8 public constant RM_TRY_RECIP_INTENT = 6;

    /// @param recipient Used for `tryModifyLiquiditiesWithRecipient` re-entry modes (must be non-zero for the facade).
    function setReentry(
        address facade_,
        uint8 mode,
        BalanceDelta bd,
        VaultSettlementIntent memory vi,
        address recipient
    ) external {
        _reFacade = facade_;
        _reMode = mode;
        _reBd = bd;
        _reVi = vi;
        _reRecipient = recipient;
    }

    function clearReentry() external {
        _reFacade = address(0);
        _reMode = 0;
    }

    function _hookBeforeModifyBalanceDelta() internal override {
        if (_reFacade == address(0) || _reMode == 0 || _reMode > 3) return;
        if (_reDepth != 0) return;
        _reDepth = 1;
        bool ok;
        if (_reMode == RM_MODIFY_BD) {
            (ok,) = _reFacade.call(abi.encodeCall(IMarketVaultModifyBd.modifyLiquidities, (_reBd)));
        } else if (_reMode == RM_TRY_BD) {
            (ok,) = _reFacade.call(abi.encodeCall(IMarketVaultTryBd.tryModifyLiquidities, (_reBd)));
        } else if (_reMode == RM_TRY_RECIP_BD) {
            (ok,) = _reFacade.call(
                abi.encodeCall(IMarketVaultTryRecipBd.tryModifyLiquiditiesWithRecipient, (_reBd, _reRecipient))
            );
        }
        _reDepth = 0;
        if (ok) revert Reentered();
    }

    function _hookBeforeModifyIntent() internal override {
        if (_reFacade == address(0) || _reMode < 4) return;
        if (_reDepth != 0) return;
        _reDepth = 1;
        bool ok;
        if (_reMode == RM_MODIFY_INTENT) {
            (ok,) = _reFacade.call(abi.encodeCall(IMarketVaultModifyIntent.modifyLiquidities, (_reVi)));
        } else if (_reMode == RM_TRY_INTENT) {
            (ok,) = _reFacade.call(abi.encodeCall(IMarketVaultTryIntent.tryModifyLiquidities, (_reVi)));
        } else if (_reMode == RM_TRY_RECIP_INTENT) {
            (ok,) = _reFacade.call(
                abi.encodeCall(IMarketVaultTryRecipIntent.tryModifyLiquiditiesWithRecipient, (_reVi, _reRecipient))
            );
        }
        _reDepth = 0;
        if (ok) revert Reentered();
    }
}

/// @notice Concrete facade for tests (fills abstract routing hooks).
contract MarketVaultFacadeHarness is MarketVaultFacade {
    Currency internal immutable currency0;
    Currency internal immutable currency1;
    ILCC internal immutable lccToken0;
    ILCC internal immutable lccToken1;
    bytes32 internal immutable marketId_;

    constructor(address marketFactory_, Currency c0, Currency c1, ILCC l0, ILCC l1, bytes32 mid_)
        MarketVaultFacade(marketFactory_)
    {
        currency0 = c0;
        currency1 = c1;
        lccToken0 = l0;
        lccToken1 = l1;
        marketId_ = mid_;
    }

    function _underlying() internal view override returns (Currency, Currency) {
        return (currency0, currency1);
    }

    function _lccs() internal view override returns (ILCC, ILCC) {
        return (lccToken0, lccToken1);
    }

    function _marketId() internal view override returns (bytes32) {
        return marketId_;
    }

    /// @dev Exposes internal `_cancelLCCWithDeficit` for `SwapDeficit` emission coverage.
    function exposed_cancelLCCWithDeficit(
        PoolKey calldata poolKey,
        ILCC lccToken,
        uint256 amount,
        address deficitRecipient
    ) external returns (uint256 amountCancelled) {
        return _cancelLCCWithDeficit(poolKey, lccToken, amount, deficitRecipient);
    }
}

contract MarketVaultFacadeTest is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant MID = keccak256("facade-unit");

    FacadeUnitTestFactory internal factory;
    MockCanonicalForFacade internal canonical;
    MarketVaultFacadeHarness internal facade;
    address internal lccAddr0;
    address internal lccAddr1;
    address internal uAddr0;
    address internal uAddr1;

    address internal boundCaller = makeAddr("boundCaller");
    address internal vts = makeAddr("vts");

    function setUp() public {
        factory = new FacadeUnitTestFactory();
        canonical = new MockCanonicalForFacade();
        factory.setCanonicalVault(address(canonical));
        factory.setVts(vts);

        MockERC20 ua = new MockERC20("A", "A", 18);
        MockERC20 ub = new MockERC20("B", "B", 18);
        MockLCC l0;
        MockLCC l1;
        uAddr0 = address(ua);
        uAddr1 = address(ub);
        if (uAddr0 > uAddr1) (uAddr0, uAddr1) = (uAddr1, uAddr0);

        for (uint256 i = 0; i < 64; i++) {
            l0 = new MockLCC("L0", "L0", 18, uAddr0);
            l1 = new MockLCC("L1", "L1", 18, uAddr1);
            if (address(l0) < address(l1)) {
                lccAddr0 = address(l0);
                lccAddr1 = address(l1);
                facade = new MarketVaultFacadeHarness(
                    address(factory), Currency.wrap(uAddr0), Currency.wrap(uAddr1), ILCC(lccAddr0), ILCC(lccAddr1), MID
                );
                break;
            }
        }
        require(address(facade) != address(0), "facade deploy");

        canonical.setDryReturn(toBalanceDelta(0, 0));
        canonical.setModifyReturn(toBalanceDelta(0, 0));
        canonical.setEchoModify(false);
    }

    function test_forwarders_marketId_canonicalVault_lccs() public view {
        assertEq(facade.marketId(), MID);
        assertEq(facade.canonicalVault(), address(canonical));
        (address t0, address t1) = facade.lccs();
        assertEq(t0, lccAddr0);
        assertEq(t1, lccAddr1);
    }

    function test_canonicalVault_revertsWhenUnset() public {
        FacadeUnitTestFactory f2 = new FacadeUnitTestFactory();
        f2.setVts(vts);
        f2.setCanonicalVault(address(0));
        MockERC20 ua = new MockERC20("A2", "A2", 18);
        MockERC20 ub = new MockERC20("B2", "B2", 18);
        address u0 = address(ua);
        address u1 = address(ub);
        if (u0 > u1) (u0, u1) = (u1, u0);
        MockLCC l0;
        MockLCC l1;
        MarketVaultFacadeHarness hAddr;
        for (uint256 i = 0; i < 64; i++) {
            l0 = new MockLCC("L0", "L0", 18, u0);
            l1 = new MockLCC("L1", "L1", 18, u1);
            if (address(l0) < address(l1)) {
                hAddr = new MarketVaultFacadeHarness(
                    address(f2), Currency.wrap(u0), Currency.wrap(u1), ILCC(address(l0)), ILCC(address(l1)), MID
                );
                break;
            }
        }
        require(address(hAddr) != address(0), "harness deploy");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        hAddr.canonicalVault();
    }

    function test_dryModifyLiquidities_expectCall_forwardsBalanceDeltaOverload() public {
        BalanceDelta wantRet = toBalanceDelta(-1, 2);
        canonical.setDryReturn(wantRet);
        BalanceDelta arg = toBalanceDelta(5, -3);

        vm.expectCall(
            address(canonical),
            abi.encodeCall(
                ICanonicalDryBd.dryModifyLiquidities, (MID, Currency.wrap(uAddr0), Currency.wrap(uAddr1), arg)
            )
        );
        BalanceDelta o = facade.dryModifyLiquidities(arg);
        assertEq(BalanceDelta.unwrap(o), BalanceDelta.unwrap(wantRet));
    }

    function test_inMarketBalanceOf_expectCall_forwardsMarketIdAndCurrency() public {
        Currency c = Currency.wrap(uAddr0);
        vm.expectCall(address(canonical), abi.encodeCall(ICanonicalInMarket.inMarketBalanceOf, (MID, c)));
        uint256 b = facade.inMarketBalanceOf(c);
        assertEq(b, 0);
    }

    function test_dryModifyLiquidities_expectCall_forwardsIntentOverload() public {
        BalanceDelta wantRet = toBalanceDelta(1, -1);
        canonical.setDryReturn(wantRet);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(3, -4), creditBackedWithdrawal0: 7, creditBackedWithdrawal1: 1
        });

        vm.expectCall(
            address(canonical),
            abi.encodeCall(
                ICanonicalDryIntent.dryModifyLiquidities, (MID, Currency.wrap(uAddr0), Currency.wrap(uAddr1), vi)
            )
        );
        BalanceDelta o = facade.dryModifyLiquidities(vi);
        assertEq(BalanceDelta.unwrap(o), BalanceDelta.unwrap(wantRet));
    }

    function test_tryModifyLiquidities_captures_routing_msgSender() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(true);
        BalanceDelta req = toBalanceDelta(2, -1);
        vm.prank(boundCaller);
        facade.tryModifyLiquidities(req);
        assertEq(canonical.lastModifyKind(), 1);
        assertEq(canonical.lastModifyMarketId(), MID);
        assertEq(Currency.unwrap(canonical.lastModifyC0()), uAddr0);
        assertEq(Currency.unwrap(canonical.lastModifyC1()), uAddr1);
        assertEq(canonical.lastModifyLcc0(), lccAddr0);
        assertEq(canonical.lastModifyLcc1(), lccAddr1);
        assertEq(canonical.lastModifyRecipient(), boundCaller);
        assertEq(BalanceDelta.unwrap(canonical.lastModifyBalanceDelta()), BalanceDelta.unwrap(req));
    }

    function test_tryModifyLiquidities_intent_captures_routing() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(true);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, 2), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        facade.tryModifyLiquidities(vi);
        assertEq(canonical.lastModifyKind(), 2);
        assertEq(canonical.lastModifyRecipient(), boundCaller);
        (BalanceDelta storedRd,,) = canonical.lastModifyIntent();
        assertEq(BalanceDelta.unwrap(storedRd), BalanceDelta.unwrap(vi.requestedDelta));
    }

    function test_tryModifyLiquiditiesWithRecipient_captures_customRecipient() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(true);
        address recipient = makeAddr("recipient");
        vm.prank(boundCaller);
        facade.tryModifyLiquiditiesWithRecipient(toBalanceDelta(0, 3), recipient);
        assertEq(canonical.lastModifyRecipient(), recipient);

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 3), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        facade.tryModifyLiquiditiesWithRecipient(vi, recipient);
        assertEq(canonical.lastModifyRecipient(), recipient);
    }

    /// @dev Full routing for both `tryModifyLiquiditiesWithRecipient` overloads (kills dropped forwarder-field mutants).
    function test_tryModifyLiquiditiesWithRecipient_fullRouting_balanceDelta_and_intent() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(true);
        address recipient = makeAddr("recipientFull");
        BalanceDelta bd = toBalanceDelta(4, -2);
        vm.prank(boundCaller);
        facade.tryModifyLiquiditiesWithRecipient(bd, recipient);
        assertEq(canonical.lastModifyKind(), 1);
        assertEq(canonical.lastModifyMarketId(), MID);
        assertEq(Currency.unwrap(canonical.lastModifyC0()), uAddr0);
        assertEq(Currency.unwrap(canonical.lastModifyC1()), uAddr1);
        assertEq(canonical.lastModifyLcc0(), lccAddr0);
        assertEq(canonical.lastModifyLcc1(), lccAddr1);
        assertEq(canonical.lastModifyRecipient(), recipient);
        assertEq(BalanceDelta.unwrap(canonical.lastModifyBalanceDelta()), BalanceDelta.unwrap(bd));

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(2, 3), creditBackedWithdrawal0: 1, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        facade.tryModifyLiquiditiesWithRecipient(vi, recipient);
        assertEq(canonical.lastModifyKind(), 2);
        assertEq(canonical.lastModifyMarketId(), MID);
        assertEq(Currency.unwrap(canonical.lastModifyC0()), uAddr0);
        assertEq(Currency.unwrap(canonical.lastModifyC1()), uAddr1);
        assertEq(canonical.lastModifyLcc0(), lccAddr0);
        assertEq(canonical.lastModifyLcc1(), lccAddr1);
        assertEq(canonical.lastModifyRecipient(), recipient);
        (BalanceDelta storedRd, uint256 cb0, uint256 cb1) = canonical.lastModifyIntent();
        assertEq(BalanceDelta.unwrap(storedRd), BalanceDelta.unwrap(vi.requestedDelta));
        assertEq(cb0, vi.creditBackedWithdrawal0);
        assertEq(cb1, vi.creditBackedWithdrawal1);
    }

    function test_onlyProtocolBounds_blocks_modifyLiquidities() public {
        canonical.setModifyReturn(toBalanceDelta(1, 0));
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.modifyLiquidities(toBalanceDelta(1, 0));
    }

    function test_onlyProtocolBounds_blocks_modifyLiquidities_intent() public {
        canonical.setModifyReturn(toBalanceDelta(1, 0));
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.modifyLiquidities(vi);
    }

    function test_onlyProtocolBounds_blocks_tryModifyLiquidities() public {
        canonical.setModifyReturn(toBalanceDelta(1, 0));
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.tryModifyLiquidities(toBalanceDelta(1, 0));
    }

    function test_onlyProtocolBounds_blocks_tryModifyLiquidities_intent() public {
        canonical.setModifyReturn(toBalanceDelta(1, 0));
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.tryModifyLiquidities(vi);
    }

    function test_onlyProtocolBounds_blocks_tryModifyLiquiditiesWithRecipient_intent() public {
        address recipient = makeAddr("recvIntentUnbound");
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.tryModifyLiquiditiesWithRecipient(vi, recipient);
    }

    function test_onlyProtocolBounds_blocks_tryModifyLiquiditiesWithRecipient_balanceDelta() public {
        address recipient = makeAddr("recvBdUnbound");
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.tryModifyLiquiditiesWithRecipient(toBalanceDelta(1, 0), recipient);
    }

    function test_tryModifyLiquidities_allOverload_successWhenBound() public {
        factory.setBound(boundCaller, true);
        canonical.setModifyReturn(toBalanceDelta(2, -1));
        vm.prank(boundCaller);
        BalanceDelta r0 = facade.tryModifyLiquidities(toBalanceDelta(2, -1));
        assertEq(BalanceDelta.unwrap(r0), BalanceDelta.unwrap(toBalanceDelta(2, -1)));

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, 1), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        BalanceDelta r1 = facade.tryModifyLiquidities(vi);
        assertEq(BalanceDelta.unwrap(r1), BalanceDelta.unwrap(toBalanceDelta(2, -1)));
    }

    function test_tryModifyLiquiditiesWithRecipient_successWhenBound() public {
        factory.setBound(boundCaller, true);
        canonical.setModifyReturn(toBalanceDelta(0, 3));
        address recipient = makeAddr("recipient");
        vm.prank(boundCaller);
        BalanceDelta r0 = facade.tryModifyLiquiditiesWithRecipient(toBalanceDelta(0, 3), recipient);
        assertEq(BalanceDelta.unwrap(r0), BalanceDelta.unwrap(toBalanceDelta(0, 3)));

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 3), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        BalanceDelta r1 = facade.tryModifyLiquiditiesWithRecipient(vi, recipient);
        assertEq(BalanceDelta.unwrap(r1), BalanceDelta.unwrap(toBalanceDelta(0, 3)));
    }

    function test_modifyLiquidities_revertsOnDeltaMismatch() public {
        factory.setBound(boundCaller, true);
        canonical.setModifyReturn(toBalanceDelta(1, 0));
        vm.prank(boundCaller);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        facade.modifyLiquidities(toBalanceDelta(3, 0));
    }

    /// @dev `tryModifyLiquidities` returns the canonical partial delta; strict `modifyLiquidities` reverts on mismatch.
    function test_tryModifyLiquidities_returnsPartialWhile_modifyLiquidities_reverts() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(false);
        BalanceDelta req = toBalanceDelta(3, 0);
        BalanceDelta usedPartial = toBalanceDelta(1, 0);
        canonical.setModifyReturn(usedPartial);

        vm.prank(boundCaller);
        BalanceDelta got = facade.tryModifyLiquidities(req);
        assertEq(BalanceDelta.unwrap(got), BalanceDelta.unwrap(usedPartial));

        vm.prank(boundCaller);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        facade.modifyLiquidities(req);
    }

    function test_tryModifyLiquidities_intent_returnsPartialWhile_modifyLiquidities_reverts() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(false);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 5), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        BalanceDelta usedPartial = toBalanceDelta(0, 2);
        canonical.setModifyReturn(usedPartial);

        vm.prank(boundCaller);
        BalanceDelta got = facade.tryModifyLiquidities(vi);
        assertEq(BalanceDelta.unwrap(got), BalanceDelta.unwrap(usedPartial));

        vm.prank(boundCaller);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        facade.modifyLiquidities(vi);
    }

    function test_modifyLiquidities_VTSIntent_revertsOnMismatch() public {
        factory.setBound(boundCaller, true);
        canonical.setModifyReturn(toBalanceDelta(0, 1));
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 5), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        vm.expectRevert(Errors.InsufficientLiquidityToTake.selector);
        facade.modifyLiquidities(vi);
    }

    function test_modifyLiquidities_succeedsWhenCanonicalMatches_request() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(true);
        BalanceDelta req = toBalanceDelta(4, 0);
        vm.prank(boundCaller);
        facade.modifyLiquidities(req);
    }

    function test_modifyLiquidities_intent_succeedsWhenCanonicalMatches_request() public {
        factory.setBound(boundCaller, true);
        canonical.setEchoModify(true);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 2), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        facade.modifyLiquidities(vi);
    }

    function test_tryModifyLiquiditiesWithRecipient_revertsZeroRecipient() public {
        factory.setBound(boundCaller, true);
        vm.prank(boundCaller);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        facade.tryModifyLiquiditiesWithRecipient(toBalanceDelta(1, 0), address(0));

        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        vm.prank(boundCaller);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        facade.tryModifyLiquiditiesWithRecipient(vi, address(0));
    }

    function test_onlyVTS_reserveMutations() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        facade.increaseLiquidityReserve(Currency.wrap(address(1)), 1);

        vm.prank(vts);
        facade.increaseLiquidityReserve(Currency.wrap(address(1)), 1);

        vm.expectRevert(Errors.InvalidSender.selector);
        facade.decreaseLiquidityReserve(Currency.wrap(address(1)), 1);

        vm.prank(vts);
        facade.decreaseLiquidityReserve(Currency.wrap(address(1)), 1);
    }

    function test_increaseLiquidityReserve_expectCall_forwardsMarketIdCurrencyAmount() public {
        Currency c = Currency.wrap(uAddr0);
        uint256 amt = 99;
        vm.expectCall(address(canonical), abi.encodeCall(ICanonicalReserveInc.increaseLiquidityReserve, (MID, c, amt)));
        vm.prank(vts);
        facade.increaseLiquidityReserve(c, amt);
    }

    function test_decreaseLiquidityReserve_expectCall_forwardsMarketIdCurrencyAmount() public {
        Currency c = Currency.wrap(uAddr1);
        uint256 amt = 77;
        vm.expectCall(address(canonical), abi.encodeCall(ICanonicalReserveDec.decreaseLiquidityReserve, (MID, c, amt)));
        vm.prank(vts);
        facade.decreaseLiquidityReserve(c, amt);
    }

    function test_receive_acceptsCanonicalBoundsAndSelf() public {
        vm.deal(address(canonical), 1);
        vm.prank(address(canonical));
        (bool okC,) = address(facade).call{value: 1}("");
        assertTrue(okC);

        factory.setBound(boundCaller, true);
        vm.deal(boundCaller, 1);
        vm.prank(boundCaller);
        (bool okB,) = address(facade).call{value: 1}("");
        assertTrue(okB);

        vm.deal(address(facade), 2);
        vm.prank(address(facade));
        (bool okSelf,) = address(facade).call{value: 1}("");
        assertTrue(okSelf);
    }

    function test_receive_rejectsStranger() public {
        address stranger = makeAddr("strangerEth");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(Errors.InvalidEthSender.selector);
        (bool ok,) = address(facade).call{value: 1 wei}("");
        ok;
    }

    /// @dev Exercises `SwapDeficit` on the facade module path (not only via `CanonicalVault` unit tests).
    function test_exposed_cancelLCCWithDeficit_partial_emitsSwapDeficit() public {
        canonical.setCancelReturn(4);
        address deficitRecipient = makeAddr("deficitRecipient");
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(uAddr0),
            currency1: Currency.wrap(uAddr1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x1234))
        });
        PoolId pid = pk.toId();

        vm.expectEmit(true, true, true, true);
        emit MarketVaultFacade.SwapDeficit(pid, lccAddr0, deficitRecipient, 6);

        uint256 cancelled = facade.exposed_cancelLCCWithDeficit(pk, ILCC(lccAddr0), 10, deficitRecipient);
        assertEq(cancelled, 4);
    }

    /// @dev Full cancel: no `SwapDeficit` (branch requires partial cancel + non-zero recipient).
    function test_exposed_cancelLCCWithDeficit_fullCancel_nonZeroRecipient_doesNotEmitSwapDeficit() public {
        canonical.setCancelReturn(10);
        address deficitRecipient = makeAddr("deficitRecipientFull");
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(uAddr0),
            currency1: Currency.wrap(uAddr1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x4321))
        });

        vm.recordLogs();
        uint256 cancelled = facade.exposed_cancelLCCWithDeficit(pk, ILCC(lccAddr0), 10, deficitRecipient);
        assertEq(cancelled, 10);
        assertEq(_countSwapDeficitLogs(address(facade)), 0);
    }

    /// @dev Partial cancel with zero recipient: must not emit `SwapDeficit` on the facade helper path.
    function test_exposed_cancelLCCWithDeficit_partial_zeroRecipient_doesNotEmitSwapDeficit() public {
        canonical.setCancelReturn(4);
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(uAddr0),
            currency1: Currency.wrap(uAddr1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x2222))
        });

        vm.recordLogs();
        uint256 cancelled = facade.exposed_cancelLCCWithDeficit(pk, ILCC(lccAddr0), 10, address(0));
        assertEq(cancelled, 4);
        assertEq(_countSwapDeficitLogs(address(facade)), 0);
    }

    function _countSwapDeficitLogs(address emitter) internal returns (uint256 c) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("SwapDeficit(bytes32,address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                unchecked {
                    ++c;
                }
            }
        }
    }
}

/// @dev Kills Gambit mutants that drop `nonReentrant` on `MarketVaultFacade` liquidity entrypoints.
contract MarketVaultFacadeReentrancyMutationTest is Test {
    bytes32 internal constant MID_RE = keccak256("facade-reentrancy");

    FacadeUnitTestFactory internal factory;
    ReentrantCanonicalForFacade internal canonical;
    MarketVaultFacadeHarness internal facade;
    address internal lccAddr0;
    address internal lccAddr1;
    address internal uAddr0;
    address internal uAddr1;

    address internal boundCaller = makeAddr("boundCallerRe");
    address internal vts = makeAddr("vtsRe");
    address internal customRecipient = makeAddr("customRecipientRe");

    function setUp() public {
        factory = new FacadeUnitTestFactory();
        canonical = new ReentrantCanonicalForFacade();
        factory.setCanonicalVault(address(canonical));
        factory.setVts(vts);
        factory.setBound(address(canonical), true);

        MockERC20 ua = new MockERC20("AR", "AR", 18);
        MockERC20 ub = new MockERC20("BR", "BR", 18);
        uAddr0 = address(ua);
        uAddr1 = address(ub);
        if (uAddr0 > uAddr1) (uAddr0, uAddr1) = (uAddr1, uAddr0);

        MockLCC l0;
        MockLCC l1;
        for (uint256 i = 0; i < 64; i++) {
            l0 = new MockLCC("L0R", "L0R", 18, uAddr0);
            l1 = new MockLCC("L1R", "L1R", 18, uAddr1);
            if (address(l0) < address(l1)) {
                lccAddr0 = address(l0);
                lccAddr1 = address(l1);
                facade = new MarketVaultFacadeHarness(
                    address(factory),
                    Currency.wrap(uAddr0),
                    Currency.wrap(uAddr1),
                    ILCC(lccAddr0),
                    ILCC(lccAddr1),
                    MID_RE
                );
                break;
            }
        }
        require(address(facade) != address(0), "facade deploy");

        canonical.setDryReturn(toBalanceDelta(0, 0));
        canonical.setModifyReturn(toBalanceDelta(0, 0));
        canonical.setEchoModify(true);
    }

    function _emptyIntent() internal pure returns (VaultSettlementIntent memory vi) {
        vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(0, 0), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
    }

    function test_modifyLiquidities_revertsIfNonReentrantRemoved_viaCanonicalReentry() public {
        factory.setBound(boundCaller, true);
        BalanceDelta bd = toBalanceDelta(3, -2);
        canonical.setReentry(address(facade), canonical.RM_MODIFY_BD(), bd, _emptyIntent(), address(0));
        vm.prank(boundCaller);
        facade.modifyLiquidities(bd);
    }

    function test_modifyLiquidities_intent_revertsIfNonReentrantRemoved_viaCanonicalReentry() public {
        factory.setBound(boundCaller, true);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(1, -1), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        canonical.setReentry(address(facade), canonical.RM_MODIFY_INTENT(), toBalanceDelta(0, 0), vi, address(0));
        vm.prank(boundCaller);
        facade.modifyLiquidities(vi);
    }

    function test_tryModifyLiquidities_revertsIfNonReentrantRemoved_viaCanonicalReentry() public {
        factory.setBound(boundCaller, true);
        BalanceDelta bd = toBalanceDelta(-5, 1);
        canonical.setReentry(address(facade), canonical.RM_TRY_BD(), bd, _emptyIntent(), address(0));
        vm.prank(boundCaller);
        BalanceDelta r = facade.tryModifyLiquidities(bd);
        assertEq(BalanceDelta.unwrap(r), BalanceDelta.unwrap(bd));
    }

    function test_tryModifyLiquidities_intent_revertsIfNonReentrantRemoved_viaCanonicalReentry() public {
        factory.setBound(boundCaller, true);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(2, 2), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        canonical.setReentry(address(facade), canonical.RM_TRY_INTENT(), toBalanceDelta(0, 0), vi, address(0));
        vm.prank(boundCaller);
        BalanceDelta r = facade.tryModifyLiquidities(vi);
        assertEq(BalanceDelta.unwrap(r), BalanceDelta.unwrap(vi.requestedDelta));
    }

    function test_tryModifyLiquiditiesWithRecipient_revertsIfNonReentrantRemoved_viaCanonicalReentry() public {
        factory.setBound(boundCaller, true);
        BalanceDelta bd = toBalanceDelta(0, 7);
        canonical.setReentry(address(facade), canonical.RM_TRY_RECIP_BD(), bd, _emptyIntent(), customRecipient);
        vm.prank(boundCaller);
        BalanceDelta r = facade.tryModifyLiquiditiesWithRecipient(bd, customRecipient);
        assertEq(BalanceDelta.unwrap(r), BalanceDelta.unwrap(bd));
    }

    function test_tryModifyLiquiditiesWithRecipient_intent_revertsIfNonReentrantRemoved_viaCanonicalReentry() public {
        factory.setBound(boundCaller, true);
        VaultSettlementIntent memory vi = VaultSettlementIntent({
            requestedDelta: toBalanceDelta(-1, 4), creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        canonical.setReentry(
            address(facade), canonical.RM_TRY_RECIP_INTENT(), toBalanceDelta(0, 0), vi, customRecipient
        );
        vm.prank(boundCaller);
        BalanceDelta r = facade.tryModifyLiquiditiesWithRecipient(vi, customRecipient);
        assertEq(BalanceDelta.unwrap(r), BalanceDelta.unwrap(vi.requestedDelta));
    }
}
