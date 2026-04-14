// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {CanonicalVault} from "../../src/modules/CanonicalVault.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract MockLiquidityHub_CanonicalVault {
    function confirmTake(address, uint256, bool) external pure {}

    function unfundedQueueOfUnderlying(address) external pure returns (uint256) {
        return 0;
    }
}

contract MockPoolManager_CanonicalVault {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isOperator;

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        return true;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(msg.sender == from || isOperator[from][msg.sender], "not operator");
        balanceOf[from][id] -= amount;
    }

    function take(Currency currency, address to, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function sync(Currency) external pure {}

    function settle() external payable returns (uint256) {
        return msg.value;
    }
}

contract MockFactory_CanonicalVault {
    address public immutable vts;
    mapping(bytes32 => mapping(address => bool)) internal _isFacade;

    constructor(address vts_) {
        vts = vts_;
    }

    function setFacade(bytes32 marketId, address facade, bool allowed) external {
        _isFacade[marketId][facade] = allowed;
    }

    function isMarketFacade(bytes32 marketId, address facade) external view returns (bool) {
        return _isFacade[marketId][facade];
    }
}

contract CanonicalVaultReallocationTest is Test {
    bytes32 internal constant MARKET_A = bytes32(uint256(1));
    bytes32 internal constant MARKET_B = bytes32(uint256(2));

    address internal owner = makeAddr("owner");
    address internal vts = makeAddr("vts");
    address internal facadeA = makeAddr("facadeA");
    address internal facadeB = makeAddr("facadeB");
    address internal recipient = makeAddr("recipient");

    MockERC20 internal underlying;
    MockERC20 internal otherUnderlying;
    MockPoolManager_CanonicalVault internal poolManager;
    MockLiquidityHub_CanonicalVault internal liquidityHub;
    MockFactory_CanonicalVault internal factory;
    CanonicalVault internal canonicalVault;

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND", 18);
        otherUnderlying = new MockERC20("Other", "OTH", 18);
        poolManager = new MockPoolManager_CanonicalVault();
        liquidityHub = new MockLiquidityHub_CanonicalVault();
        factory = new MockFactory_CanonicalVault(vts);

        vm.prank(owner);
        canonicalVault = new CanonicalVault(address(poolManager), address(liquidityHub), owner);
        vm.prank(owner);
        canonicalVault.bindFactory(address(factory));

        factory.setFacade(MARKET_A, facadeA, true);
        factory.setFacade(MARKET_B, facadeB, true);

        vm.prank(address(factory));
        canonicalVault.registerMarket(
            MARKET_A, facadeA, address(0x1001), address(0x1002), address(underlying), address(otherUnderlying)
        );
        vm.prank(address(factory));
        canonicalVault.registerMarket(
            MARKET_B, facadeB, address(0x2001), address(0x2002), address(underlying), address(otherUnderlying)
        );

        underlying.mint(address(poolManager), 200e18);
    }

    function test_recordCreditProductionAndDepositConsumption_reallocatesLedgerAcrossMarkets() public {
        vm.prank(facadeA);
        canonicalVault.takeUnderlyingClaims(MARKET_A, Currency.wrap(address(underlying)), 100e18);

        vm.prank(vts);
        canonicalVault.recordCreditProduction(MARKET_A, Currency.wrap(address(underlying)), 40e18);

        vm.prank(vts);
        canonicalVault.recordCreditConsumptionForDeposit(MARKET_B, Currency.wrap(address(underlying)), 40e18);

        assertEq(canonicalVault.inMarketBalanceOf(MARKET_A, Currency.wrap(address(underlying))), 60e18);
        assertEq(canonicalVault.inMarketBalanceOf(MARKET_B, Currency.wrap(address(underlying))), 40e18);

        canonicalVault.assertNoPendingReallocations();
    }

    function test_creditBackedWithdrawal_canConsumeCreditProducedByAnotherMarket() public {
        vm.prank(facadeA);
        canonicalVault.takeUnderlyingClaims(MARKET_A, Currency.wrap(address(underlying)), 100e18);

        vm.prank(vts);
        canonicalVault.recordCreditProduction(MARKET_A, Currency.wrap(address(underlying)), 40e18);

        vm.prank(vts);
        canonicalVault.recordCreditConsumptionForWithdrawal(MARKET_B, Currency.wrap(address(underlying)), 40e18);

        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        canonicalVault.assertNoPendingReallocations();

        vm.prank(facadeB);
        BalanceDelta dryDelta = canonicalVault.dryModifyLiquidities(
            MARKET_B,
            Currency.wrap(address(underlying)),
            Currency.wrap(address(otherUnderlying)),
            toBalanceDelta(int128(40e18), 0)
        );
        assertEq(dryDelta.amount0(), 40e18);
        assertEq(dryDelta.amount1(), 0);

        vm.prank(facadeB);
        BalanceDelta usedDelta = canonicalVault.modifyLiquidities(
            MARKET_B,
            Currency.wrap(address(underlying)),
            Currency.wrap(address(otherUnderlying)),
            address(0x2001),
            address(0x2002),
            toBalanceDelta(int128(40e18), 0),
            recipient
        );

        assertEq(usedDelta.amount0(), 40e18);
        assertEq(uint256(underlying.balanceOf(recipient)), 40e18);
        assertEq(canonicalVault.inMarketBalanceOf(MARKET_A, Currency.wrap(address(underlying))), 60e18);
        assertEq(canonicalVault.inMarketBalanceOf(MARKET_B, Currency.wrap(address(underlying))), 0);

        canonicalVault.assertNoPendingReallocations();
    }
}
