// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Bounds} from "../src/libraries/Bounds.sol";
import {Vm} from "forge-std/Vm.sol";

contract MockMarketVaultForEthReceive {
    address internal _lcc0;
    address internal _lcc1;

    constructor(address lcc0_, address lcc1_) {
        _lcc0 = lcc0_;
        _lcc1 = lcc1_;
    }

    function lccs() external view returns (address, address) {
        return (_lcc0, _lcc1);
    }

    function sendEth(address payable to, uint256 amount) external {
        (bool ok, bytes memory data) = to.call{value: amount}("");
        if (!ok) {
            // Bubble revert data so tests can assert on the underlying custom error.
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    receive() external payable {}
}

contract MockMarketVaultWithInvalidLccs {
    function lccs() external pure returns (address, address) {
        // Not valid LCC addresses.
        return (address(0xBADD), address(0xF00D));
    }

    function sendEth(address payable to, uint256 amount) external {
        (bool ok, bytes memory data) = to.call{value: amount}("");
        if (!ok) {
            // Bubble revert data so tests can assert on the underlying custom error.
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    receive() external payable {}
}

contract MockSenderWithoutLccsSelector {
    function sendEth(address payable to, uint256 amount) external {
        (bool ok, bytes memory data) = to.call{value: amount}("");
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    receive() external payable {}
}

/**
 * @title LiquidityHubTest
 * @notice Core unit tests for LiquidityHub admin/accessors and edge cases.
 */
contract LiquidityHubTest is LiquidityHubTestBase {
    event FactorySet(address indexed factory, bool enabled);
    event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
    event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
    event SettlementProcessed(address indexed lcc, address indexed recipient, uint256 amount);
    event BoundLevelSet(address indexed factory, address indexed who, uint8 level);

    function test_setFactory_revertsWhenNotOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        liquidityHub.setFactory(makeAddr("factory"), true);
    }

    function test_setFactory_emitsEvent() public {
        address f = makeAddr("factory2");

        vm.expectEmit(true, false, false, true);
        emit FactorySet(f, true);

        liquidityHub.setFactory(f, true);
        assertTrue(liquidityHub.isFactory(f));
    }

    function test_setBoundLevel_revertsWhenNotFactory() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        liquidityHub.setBoundLevel(makeAddr("who"), 1);
    }

    function test_setBoundLevels_revertsWhenNotFactory() public {
        address[] memory who = new address[](2);
        who[0] = makeAddr("who0");
        who[1] = makeAddr("who1");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        liquidityHub.setBoundLevels(who, 1);
    }

    function test_setBoundLevel_setsLevelInCallerFactoryNamespace_andEmitsEvent() public {
        address who = makeAddr("newEndpoint");
        uint8 level = 1;

        vm.expectEmit(true, true, false, true);
        emit BoundLevelSet(factory, who, level);

        vm.prank(factory);
        liquidityHub.setBoundLevel(who, level);

        assertEq(liquidityHub.boundLevel(factory, who), level);
    }

    function test_setFactory_canDisableFactory() public {
        address f = makeAddr("factoryDisable");
        liquidityHub.setFactory(f, true);
        assertTrue(liquidityHub.isFactory(f));

        liquidityHub.setFactory(f, false);
        assertFalse(liquidityHub.isFactory(f));
    }

    function test_createLCCPair_revertsWhenNotFactory() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        liquidityHub.createLCCPair(
            abi.encodePacked(address(0x1234)),
            address(underlyingAsset1),
            address(underlyingAsset2),
            "",
            new address[](0)
        );
    }

    function test_initialize_revertsWhenNotFactory() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        liquidityHub.initialize(lccToken1, lccToken2, bytes32("m"), abi.encodePacked(address(0x1234)));
    }

    function test_getFactory_revertsWhenFactoriesMismatch() public {
        // Create an additional market from a second factory address.
        address factory2 = makeAddr("FACTORY_2");
        liquidityHub.setFactory(factory2, true);

        // Mock oracleHelper() for factory2.
        vm.mockCall(
            factory2, abi.encodeWithSelector(IMarketFactory.oracleHelper.selector), abi.encode(address(oracleHelper))
        );

        address lccA;
        address lccB;
        vm.startPrank(factory2);
        address[] memory issuers = new address[](1);
        issuers[0] = factory2;
        (lccA, lccB) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x5678)),
            address(underlyingAsset1),
            address(underlyingAsset2),
            "Test Market 2",
            issuers
        );
        liquidityHub.initialize(lccA, lccB, bytes32("market2"), abi.encodePacked(address(0x5678)));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Errors.InvariantViolated.selector, "LCCs are not from the same market"));
        liquidityHub.getFactory(lccToken1, lccA);
    }

    function test_marketLiquidity_returnsZeroWhenMarketMissing() public view {
        assertEq(liquidityHub.marketLiquidity(address(0xDEAD)), 0);
    }

    function test_reserveOfUnderlying_revertsForInvalidLcc() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, address(0xDEAD)));
        liquidityHub.reserveOfUnderlying(address(0xDEAD));
    }

    function test_prepareSettle_revertsWithZeroAmount() public {
        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.prepareSettle(lccToken1, 0);
    }

    function test_prepareSettle_revertsWhenReserveInsufficient() public {
        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(1), uint256(0)));
        liquidityHub.prepareSettle(lccToken1, 1);
    }

    function test_prepareSettle_approvesErc20AndDecrementsReserve() public {
        uint256 amount = 10 ether;
        _wrapDirectLCC(user1, lccToken1, amount);

        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        assertEq(reserveBefore, amount);

        vm.prank(proxyHook);
        liquidityHub.prepareSettle(lccToken1, 3 ether);

        assertEq(liquidityHub.reserveOfUnderlying(lccToken1), reserveBefore - 3 ether);
        assertEq(underlyingAsset1.allowance(address(liquidityHub), proxyHook), 3 ether);
    }

    function test_prepareSettle_transfersNativeEthAndDecrementsReserve() public {
        // Create a market where one LCC is native-asset-backed.
        address lccNative;
        address lccErc20;
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = proxyHook;
        (lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xCAFE)), address(0), address(underlyingAsset1), "Native Market", issuers
        );
        liquidityHub.initialize(lccNative, lccErc20, bytes32("nativeMarket"), abi.encodePacked(address(0xCAFE)));
        vm.stopPrank();

        // Wrap native ETH into the hub to create reserve.
        uint256 amount = 1 ether;
        uint256 proxyHookEthBefore = proxyHook.balance;
        vm.deal(proxyHook, proxyHookEthBefore + amount);
        vm.prank(proxyHook);
        liquidityHub.wrap{value: amount}(lccNative, amount);
        assertEq(liquidityHub.reserveOfUnderlying(lccNative), amount);

        // prepareSettle should transfer ETH to the issuer (caller) and decrement reserves.
        vm.prank(proxyHook);
        liquidityHub.prepareSettle(lccNative, 0.4 ether);
        assertEq(liquidityHub.reserveOfUnderlying(lccNative), amount - 0.4 ether);
        assertEq(proxyHook.balance, proxyHookEthBefore + 0.4 ether);
    }

    function test_receive_revertsFromEoaSender() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool ok,) = payable(address(liquidityHub)).call{value: 1}("");
        assertFalse(ok);
    }

    function test_receive_revertsWhenNoNativeLcc() public {
        MockMarketVaultForEthReceive vault = new MockMarketVaultForEthReceive(lccToken1, lccToken2);
        vm.deal(address(vault), 1 ether);
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.isCanonicalVault.selector, marketId1, address(vault)),
            abi.encode(true)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEthSender.selector));
        vault.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_receive_revertsWhenSenderIsNotMarketVaultContract() public {
        MockSenderWithoutLccsSelector sender = new MockSenderWithoutLccsSelector();
        vm.deal(address(sender), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEthSender.selector));
        sender.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_receive_revertsWhenMarketVaultReturnsInvalidLccs() public {
        MockMarketVaultWithInvalidLccs vault = new MockMarketVaultWithInvalidLccs();
        vm.deal(address(vault), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEthSender.selector));
        vault.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_receive_acceptsFromMarketVaultWithNativeLcc() public {
        // Create a market where one LCC is native-asset-backed.
        address lccNative;
        address lccErc20;
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xBEEF)), address(0), address(underlyingAsset1), "Native Market", issuers
        );
        liquidityHub.initialize(lccNative, lccErc20, bytes32("nativeMarket"), abi.encodePacked(address(0xBEEF)));
        vm.stopPrank();

        MockMarketVaultForEthReceive vault = new MockMarketVaultForEthReceive(lccNative, lccErc20);
        vm.deal(address(vault), 1 ether);

        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.isCanonicalVault.selector, bytes32("nativeMarket"), address(vault)),
            abi.encode(true)
        );

        // Should not revert.
        vault.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_receive_revertsWhenSenderNotCanonicalVaultForMarket() public {
        address lccNative;
        address lccErc20;
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xBEEF)), address(0), address(underlyingAsset1), "Native Market", issuers
        );
        liquidityHub.initialize(
            lccNative, lccErc20, bytes32("nativeMarketCanonical"), abi.encodePacked(address(0xBEEF))
        );
        vm.stopPrank();

        MockMarketVaultForEthReceive spoofVault = new MockMarketVaultForEthReceive(lccNative, lccErc20);
        vm.deal(address(spoofVault), 1 ether);
        vm.mockCall(
            factory,
            abi.encodeWithSelector(
                IMarketFactory.isCanonicalVault.selector, bytes32("nativeMarketCanonical"), address(spoofVault)
            ),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEthSender.selector));
        spoofVault.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_wrapTo_overloadByUnderlyingAndMarketId_works() public {
        uint256 amount = 50;
        underlyingAsset1.mint(user1, amount);

        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), amount);
        liquidityHub.wrapTo(address(underlyingAsset1), marketId1, user2, amount);
        vm.stopPrank();

        assertEq(underlyingAsset1.balanceOf(user1), 0);
        assertEq(underlyingAsset1.balanceOf(address(liquidityHub)), amount);
        assertEq(ILCC(lccToken1).balanceOf(user2), amount);
    }

    function test_wrap_native_revertsWhenMsgValueMismatch() public {
        // Create a market where one LCC is native-asset-backed.
        address lccNative;
        address lccErc20;
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xD00D)), address(0), address(underlyingAsset1), "Native Market", issuers
        );
        liquidityHub.initialize(lccNative, lccErc20, bytes32("nativeMarket2"), abi.encodePacked(address(0xD00D)));
        vm.stopPrank();

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.wrap{value: 0.9 ether}(lccNative, 1 ether);
    }

    function test_unwrap_overloadsByUnderlyingAndMarketId_work() public {
        uint256 amount = 25;

        // Wrap via (underlying, marketId) overload.
        underlyingAsset1.mint(user1, amount);
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), amount);
        liquidityHub.wrap(address(underlyingAsset1), marketId1, amount);
        vm.stopPrank();

        // Unwrap via (underlying, marketId) overload.
        vm.prank(user1);
        liquidityHub.unwrap(address(underlyingAsset1), marketId1, amount);
        assertEq(underlyingAsset1.balanceOf(user1), amount);
        assertEq(ILCC(lccToken1).balanceOf(user1), 0);

        // Wrap again and unwrapTo via overload.
        underlyingAsset1.mint(user1, amount);
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), amount);
        liquidityHub.wrap(address(underlyingAsset1), marketId1, amount);
        vm.stopPrank();

        vm.prank(user1);
        liquidityHub.unwrapTo(address(underlyingAsset1), marketId1, user2, amount);
        assertEq(underlyingAsset1.balanceOf(user2), amount);
        assertEq(ILCC(lccToken1).balanceOf(user1), 0);
    }

    function test_unwrapTo_overloadByUnderlyingMarketId_withQueueTo_attributesQueueCorrectly() public {
        uint256 amount = 25;

        // user1 has only market-derived balance.
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        // Force market liquidity to 0 so it queues.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementQueued(lccToken1, user3, amount);

        vm.prank(user1);
        liquidityHub.unwrapTo(address(underlyingAsset1), marketId1, user2, user3, amount);

        assertEq(liquidityHub.settleQueue(lccToken1, user3), amount, "queue should be attributed to queueTo");
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0, "to should not own the queued settlement");
    }

    function test_unwrap_doesNotEmitSettlementQueuedWhenNoShortfall() public {
        uint256 amount = 10;
        _wrapDirectLCC(user1, lccToken1, amount);

        vm.recordLogs();
        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, amount);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("SettlementQueued(address,address,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0) {
                require(entries[i].topics[0] != topic0, "unexpected SettlementQueued");
            }
        }
    }

    function test_unwrap_emitsSettlementQueuedOnShortfall() public {
        uint256 amount = 17;
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        // Force market path to return 0 so full amount is queued.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementQueued(lccToken1, user1, amount);

        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, amount);

        assertEq(liquidityHub.settleQueue(lccToken1, user1), amount);
    }

    function test_wrapWith_emitsSettlementQueuedWhenResidualUnwrapQueuesToHub() public {
        uint256 amount = 13;
        (address lccToken3,) = _createSecondLCCPair();

        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, user1, amount);

        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementQueued(lccToken1, address(liquidityHub), amount);
        liquidityHub.wrapWith(lccToken3, lccToken1, amount);
        vm.stopPrank();

        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), amount);
    }

    function test_issue_cancel_and_cancelWithQueue_coverIssuerPaths() public {
        uint256 amount = 100;

        // issue: issuer (factory) can mint market-derived (issued=true).
        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, user1, amount);
        assertEq(ILCC(lccToken1).balanceOf(user1), amount);

        // cancel: issuer can burn market-derived (issued=true in LCC burn path).
        vm.prank(proxyHook);
        liquidityHub.cancel(lccToken1, user1, 40);
        assertEq(ILCC(lccToken1).balanceOf(user1), 60);

        // cancelWithQueue: burn a portion now and queue the remainder for settlement.
        vm.prank(proxyHook);
        liquidityHub.cancelWithQueue(lccToken1, user1, 60, 25, user3);
        // 35 burned, 25 queued.
        assertEq(ILCC(lccToken1).balanceOf(user1), 25);
        assertEq(liquidityHub.settleQueue(lccToken1, user3), 25);
        assertEq(liquidityHub.totalQueued(lccToken1), 25);

        // queue-only branch (principal == queue): no burn, only queue.
        vm.prank(proxyHook);
        liquidityHub.cancelWithQueue(lccToken1, user1, 25, 25, user2);
        assertEq(ILCC(lccToken1).balanceOf(user1), 25);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 25);
        assertEq(liquidityHub.totalQueued(lccToken1), 50);
    }

    /// @dev Mutation-hardening: ensures `_safeBurn` correctly computes `remaining = amount - burnMarket`
    ///      by burning across mixed bucket balances (market-derived first, then wrapped).
    function test_cancelWithQueue_burnsMarketFirstThenWrapped_forMixedBucketHolder() public {
        // Give user1 wrapped balance via direct wrap.
        _wrapDirectLCC(user1, lccToken1, 40);

        // Create market-derived balance for user1 by transferring from a bucket-exempt endpoint (proxyHook).
        _wrapDirectLCC(proxyHook, lccToken1, 60);
        vm.prank(proxyHook);
        ILCC(lccToken1).transfer(user1, 60);

        (uint256 wrappedBefore, uint256 marketBefore) = ILCC(lccToken1).balancesOf(user1);
        assertEq(wrappedBefore, 40);
        assertEq(marketBefore, 60);
        assertEq(ILCC(lccToken1).balanceOf(user1), 100);

        // Burn 70 (queue 0): should consume 60 market + 10 wrapped, leaving 30 wrapped.
        vm.prank(proxyHook);
        liquidityHub.cancelWithQueue(lccToken1, user1, 70, 0, user2);

        (uint256 wrappedAfter, uint256 marketAfter) = ILCC(lccToken1).balancesOf(user1);
        assertEq(ILCC(lccToken1).balanceOf(user1), 30);
        assertEq(wrappedAfter, 30);
        assertEq(marketAfter, 0);
    }

    function test_cancelWithQueue_revertsWhenPrincipalIsZero() public {
        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.cancelWithQueue(lccToken1, user1, 0, 0, user2);
    }

    function test_cancelWithQueue_revertsWhenQueueExceedsPrincipal() public {
        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(2), uint256(1)));
        liquidityHub.cancelWithQueue(lccToken1, user1, 1, 2, user2);
    }

    function test_cancelWithQueue_doesNotEmitSettlementQueuedWhenQueueAmountIsZero() public {
        // Give user1 some market-derived balance so cancelWithQueue can burn.
        _wrapMarketDerivedLCC(user1, lccToken1, 10);

        vm.recordLogs();
        vm.prank(proxyHook);
        liquidityHub.cancelWithQueue(lccToken1, user1, 5, 0, user2);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("SettlementQueued(address,address,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0) {
                require(entries[i].topics[0] != topic0, "unexpected SettlementQueued");
            }
        }
    }

    function test_queueForTransferRecipient_revertsWhenRecipientIsExempt() public {
        uint256 amount = 10;
        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, proxyHook, amount);

        vm.prank(proxyHook);
        ILCC(lccToken1).transfer(user2, amount);
        _setBoundLevel(user2, Bounds.BOUND_EXEMPT);

        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user2));
        liquidityHub.queueForTransferRecipient(lccToken1, user2, amount);
    }

    function test_queueForTransferRecipient_revertsWhenMarketDerivedIsInsufficient() public {
        uint256 transferred = 5;
        uint256 queued = 10;
        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, proxyHook, transferred);

        vm.prank(proxyHook);
        ILCC(lccToken1).transfer(user2, transferred);

        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, transferred, queued));
        liquidityHub.queueForTransferRecipient(lccToken1, user2, queued);
    }

    function test_queueForTransferRecipient_queuesWhenRecipientBacked() public {
        uint256 amount = 12;
        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, proxyHook, amount);

        vm.prank(proxyHook);
        ILCC(lccToken1).transfer(user2, amount);

        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementQueued(lccToken1, user2, amount);

        vm.prank(proxyHook);
        liquidityHub.queueForTransferRecipient(lccToken1, user2, amount);

        assertEq(liquidityHub.settleQueue(lccToken1, user2), amount);
        assertEq(liquidityHub.totalQueued(lccToken1), amount);
    }

    function test_queueForTransferRecipient_revertsWhenCallerIsNotIssuer() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.queueForTransferRecipient(lccToken1, user2, 1);
    }

    function test_queueForTransferRecipient_revertsWhenRecipientIsZero() public {
        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        liquidityHub.queueForTransferRecipient(lccToken1, address(0), 1);
    }

    function test_queueForTransferRecipient_revertsWhenAmountIsZero() public {
        vm.prank(proxyHook);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.queueForTransferRecipient(lccToken1, user2, 0);
    }

    function test_queueForTransferRecipient_queuesWhenRecipientIsBoundEndpoint() public {
        uint256 amount = 9;
        _setBoundLevel(user2, Bounds.BOUND_ENDPOINT);

        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, proxyHook, amount);
        vm.prank(proxyHook);
        ILCC(lccToken1).transfer(user2, amount);

        vm.prank(proxyHook);
        liquidityHub.queueForTransferRecipient(lccToken1, user2, amount);

        assertEq(liquidityHub.settleQueue(lccToken1, user2), amount);
        assertEq(liquidityHub.totalQueued(lccToken1), amount);
    }

    function test_queueForTransferRecipient_accumulatesQueueForSameRecipient() public {
        uint256 amount1 = 4;
        uint256 amount2 = 7;

        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, proxyHook, amount1 + amount2);
        vm.startPrank(proxyHook);
        ILCC(lccToken1).transfer(user2, amount1 + amount2);
        liquidityHub.queueForTransferRecipient(lccToken1, user2, amount1);
        liquidityHub.queueForTransferRecipient(lccToken1, user2, amount2);
        vm.stopPrank();

        assertEq(liquidityHub.settleQueue(lccToken1, user2), amount1 + amount2);
        assertEq(liquidityHub.totalQueued(lccToken1), amount1 + amount2);
    }

    function test_annulSettlementBeforeTransfer_noOpBranchesAndBleedLogic() public {
        // Create a queue entry for user1.
        uint256 q = 40;
        _createSettlementQueueEntry(lccToken1, user1, q);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), q);
        assertEq(liquidityHub.totalQueued(lccToken1), q);

        // No-op when amountToTransfer == 0.
        vm.prank(lccToken1);
        liquidityHub.annulSettlementBeforeTransfer(user1, 0, q, 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), q);

        // No-op when queued == 0.
        vm.prank(lccToken1);
        liquidityHub.annulSettlementBeforeTransfer(user2, 10, 0, 5);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);

        // Bleed into queue: liquidBalance = 10, queued = 40 => transferableWithoutQueue = 0
        // amountToTransfer=15 => bleedIntoQueue=15 => annul 15.
        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementAnnulled(lccToken1, user1, 15);
        vm.prank(lccToken1);
        liquidityHub.annulSettlementBeforeTransfer(user1, 10, 0, 15);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), q - 15);
        assertEq(liquidityHub.totalQueued(lccToken1), q - 15);
    }

    function test_annulSettlementBeforeTransfer_bleedUsesTransferableWithoutQueue_whenLiquidBalanceExceedsQueued()
        public
    {
        // queued is large; make bleed smaller than queued so toAnnul == bleed (sensitive to arithmetic mutants).
        uint256 q = 80;
        _createSettlementQueueEntry(lccToken1, user1, q);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), q);

        // liquidBalance = 100, queued = 80 => transferableWithoutQueue = 20.
        // amountToTransfer = 30 => bleedIntoQueue = 10, toAnnul = 10.
        vm.prank(lccToken1);
        liquidityHub.annulSettlementBeforeTransfer(user1, 55, 45, 30);

        assertEq(liquidityHub.settleQueue(lccToken1, user1), q - 10);
        assertEq(liquidityHub.totalQueued(lccToken1), q - 10);
    }

    function test_confirmTake_emitsLiquidityAvailableWhenShouldEmitAndNotFullyConsumedByHubQueue() public {
        uint256 hubQueue = 5;
        uint256 amount = 10;

        // Create a queue entry for the Hub itself.
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), hubQueue);

        // `confirmTake` is balance-backed: the Hub must actually hold underlying for the reserve increment.
        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        uint256 needed = reserveBefore + amount;
        uint256 bal = underlyingAsset1.balanceOf(address(liquidityHub));
        if (bal < needed) underlyingAsset1.mint(address(liquidityHub), needed - bal);

        vm.expectEmit(true, false, false, true, address(liquidityHub));
        emit LiquidityAvailable(lccToken1, address(underlyingAsset1), amount, marketId1);

        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, amount, true);
    }

    function test_confirmTake_doesNotEmitWhenShouldEmitFalse() public {
        uint256 amount = 10;

        // `confirmTake` is balance-backed: the Hub must actually hold underlying for the reserve increment.
        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        uint256 needed = reserveBefore + amount;
        uint256 bal = underlyingAsset1.balanceOf(address(liquidityHub));
        if (bal < needed) underlyingAsset1.mint(address(liquidityHub), needed - bal);

        vm.recordLogs();
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, amount, false);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("LiquidityAvailable(address,address,uint256,bytes32)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0) {
                require(entries[i].topics[0] != topic0, "unexpected LiquidityAvailable");
            }
        }
    }

    function test_confirmTake_doesNotEmitWhenShouldEmitButFullyConsumedByHubQueue() public {
        // Create a hub queue equal to the amount (so hubQueue < amount is false).
        uint256 hubQueue = 10;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), hubQueue);

        // `confirmTake` is balance-backed: the Hub must actually hold underlying for the reserve increment.
        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        uint256 needed = reserveBefore + hubQueue;
        uint256 bal = underlyingAsset1.balanceOf(address(liquidityHub));
        if (bal < needed) underlyingAsset1.mint(address(liquidityHub), needed - bal);

        // If this emitted, the test would fail; keep it silent.
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, hubQueue, true);
    }

    function test_confirmTake_processesHubQueueWhenPresent() public {
        uint256 queued = 7;
        uint256 incoming = 10;

        // Create a queue entry for the Hub itself; Hub should also hold the LCC that will be burned on settle.
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queued);
        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), queued);

        uint256 hubLccBefore = ILCC(lccToken1).balanceOf(address(liquidityHub));
        assertEq(hubLccBefore, queued, "Hub should hold queued LCC for hub-settlement path");

        // `confirmTake` is balance-backed: the Hub must actually hold underlying for the reserve increment.
        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        uint256 needed = reserveBefore + incoming;
        uint256 bal = underlyingAsset1.balanceOf(address(liquidityHub));
        if (bal < needed) underlyingAsset1.mint(address(liquidityHub), needed - bal);

        // confirmTake should increase reserves and then best-effort settle the Hub's own queue.
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, incoming, false);

        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0, "Hub queue should be cleared");
        assertEq(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should be decremented");
        assertEq(ILCC(lccToken1).balanceOf(address(liquidityHub)), hubLccBefore - queued, "Hub-held LCC burned");
    }
}

