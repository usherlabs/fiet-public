// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

/**
 * @notice Mutation hardening tests for LiquidityHub.
 * @dev Focused assertions to kill surviving mutants without pulling in full integration harnesses.
 */
contract LiquidityHubMutationHardeningTest is LiquidityHubTestBase {
    using stdStorage for StdStorage;

    StdStorage internal _store;

    function test_constructor_setsOracleHelper() public view {
        assertEq(address(liquidityHub.oracleHelper()), address(oracleHelper));
    }

    function test_constructor_initNativeAsset_impactsNativeLccMetadata() public {
        // Create a market where one LCC is native-asset-backed and assert its decimals match the hub's native decimals.
        address lccNative;
        address lccErc20;

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xBEEF)), address(0), address(underlyingAsset1), "Native Market", issuers
        );
        liquidityHub.initialize(lccNative, lccErc20, bytes32("nativeMarket2"), abi.encodePacked(address(0xBEEF)));
        vm.stopPrank();

        assertEq(IERC20Metadata(lccNative).decimals(), 18);
    }

    function test_setFactory_canDisableFactory() public {
        address f = makeAddr("factoryToDisable");

        liquidityHub.setFactory(f, true);
        assertTrue(liquidityHub.isFactory(f));

        liquidityHub.setFactory(f, false);
        assertFalse(liquidityHub.isFactory(f));
    }

    function test_issue_revertsWithZeroAmount() public {
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.issue(lccToken1, user1, 0);
    }

    function test_cancel_revertsWithZeroAmount() public {
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.cancel(lccToken1, user1, 0);
    }

    function test_issue_revertsForNonIssuer() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.issue(lccToken1, user1, 1);
    }

    function test_cancel_revertsForNonIssuer() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.cancel(lccToken1, user1, 1);
    }

    function test_cancelWithQueue_revertsForNonIssuer() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.cancelWithQueue(lccToken1, user1, 1, 1, user2);
    }

    function test_confirmTake_revertsForNonIssuer() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.confirmTake(lccToken1, 1, false);
    }

    function test_prepareSettle_revertsForNonIssuer() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.prepareSettle(lccToken1, 1);
    }

    function test_processSettlementFor_revertsForInvalidLcc() public {
        address invalid = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalid));
        liquidityHub.processSettlementFor(invalid, user1, type(uint256).max);
    }

    function test_executePlannedCancel_revertsWhenMsgSenderIsNotValidLcc() public {
        address notLcc = makeAddr("notLccToken");
        vm.prank(notLcc);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, notLcc));
        liquidityHub.executePlannedCancel(makeAddr("sender"), makeAddr("cancelFromRecipient"));
    }

    function test_annulSettlementBeforeTransfer_revertsWhenMsgSenderIsNotValidLcc() public {
        address notLcc = makeAddr("notLccToken");
        vm.prank(notLcc);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, notLcc));
        liquidityHub.annulSettlementBeforeTransfer(user1, 1, 0, 1);
    }

    function test_unwrapTo_overloadWithQueueTo_attributesQueueToCorrectRecipient() public {
        // Give user1 market-derived LCC and force unwrap to queue (no market liquidity).
        uint256 amount = 25;
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encode(uint256(0)) // no market liquidity
        );

        address to = user2;
        address queueTo = user3;

        vm.prank(user1);
        liquidityHub.unwrapTo(address(underlyingAsset1), marketId1, to, queueTo, amount);

        assertEq(liquidityHub.settleQueue(lccToken1, queueTo), amount, "queue should be attributed to queueTo");
        assertEq(liquidityHub.settleQueue(lccToken1, to), 0, "to should not own the queued settlement");
    }

    function test_createLCCPair_emitsLccCreatedEvents() public {
        // Using recordLogs avoids having to know the marketId ahead of time.
        vm.recordLogs();

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address a, address b) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xABCD)), address(underlyingAsset1), address(underlyingAsset2), "M", issuers
        );
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("LCCCreated(address,address,bytes32)");

        bool seenA = false;
        bool seenB = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != topic0) continue;
            address underlying = address(uint160(uint256(entries[i].topics[1])));
            address lccToken = address(uint160(uint256(entries[i].topics[2])));
            if (underlying == address(underlyingAsset1) && lccToken == a) seenA = true;
            if (underlying == address(underlyingAsset2) && lccToken == b) seenB = true;
        }

        assertTrue(seenA, "missing LCCCreated for token0");
        assertTrue(seenB, "missing LCCCreated for token1");
    }

    function test_wrapTo_emitsLccWrapped() public {
        uint256 amount = 17;
        underlyingAsset1.mint(user1, amount);

        vm.recordLogs();
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), amount);
        liquidityHub.wrapTo(lccToken1, user2, amount);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("LccWrapped(address,address,address,uint256)");

        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != topic0) continue;
            address lcc = address(uint160(uint256(entries[i].topics[1])));
            if (lcc != lccToken1) continue;
            (address from, address to, uint256 amt) = abi.decode(entries[i].data, (address, address, uint256));
            if (from == user1 && to == user2 && amt == amount) found = true;
        }

        assertTrue(found, "missing LccWrapped");
    }

    function test_unwrapTo_emitsLccUnwrapped() public {
        uint256 amount = 9;
        _wrapDirectLCC(user1, lccToken1, amount);

        vm.recordLogs();
        vm.prank(user1);
        liquidityHub.unwrapTo(lccToken1, user2, amount);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("LccUnwrapped(address,address,address,uint256)");

        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != topic0) continue;
            address lcc = address(uint160(uint256(entries[i].topics[1])));
            if (lcc != lccToken1) continue;
            (address from, address to, uint256 amt) = abi.decode(entries[i].data, (address, address, uint256));
            if (from == user1 && to == user2 && amt == amount) found = true;
        }

        assertTrue(found, "missing LccUnwrapped");
    }

    function test_wrapWithTo_emitsLccWrappedWith() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 amount = 11;

        _wrapDirectLCC(user1, lccToken1, amount);
        _mockAddressAsProtocolBound(address(liquidityHub), true);

        vm.recordLogs();
        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        liquidityHub.wrapWithTo(lccToken3, lccToken1, user2, amount);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("LccWrappedWith(address,address,address,address,uint256)");

        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != topic0) continue;
            address lcc = address(uint160(uint256(entries[i].topics[1])));
            address withLcc = address(uint160(uint256(entries[i].topics[2])));
            if (lcc != lccToken3 || withLcc != lccToken1) continue;
            (address from, address to, uint256 amt) = abi.decode(entries[i].data, (address, address, uint256));
            if (from == user1 && to == user2 && amt == amount) found = true;
        }

        assertTrue(found, "missing LccWrappedWith");
    }

    function test_cancelWithQueue_emitsSettlementQueued_whenQueuePositive() public {
        _wrapMarketDerivedLCC(user1, lccToken1, 10);

        vm.recordLogs();
        vm.prank(factory);
        liquidityHub.cancelWithQueue(lccToken1, user1, 5, 3, user2);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("SettlementQueued(address,address,uint256)");

        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != topic0) continue;
            address lcc = address(uint160(uint256(entries[i].topics[1])));
            address recipient = address(uint160(uint256(entries[i].topics[2])));
            uint256 amt = abi.decode(entries[i].data, (uint256));
            if (lcc == lccToken1 && recipient == user2 && amt == 3) found = true;
        }

        assertTrue(found, "missing SettlementQueued");
    }

    function test_issue_revertsForInvalidLcc_evenIfCallerIsIssuer() public {
        address invalid = makeAddr("invalidLcc");

        // Force onlyIssuer(invalid) to pass by setting issuers[invalid][factory] = true directly in hub storage.
        _store.target(address(liquidityHub)).sig("issuers(address,address)").with_key(invalid).with_key(factory)
            .checked_write(true);
        assertTrue(liquidityHub.issuers(invalid, factory), "issuer flag should be forced on");

        // Now onlyValidLcc(invalid) should be the gate that reverts.
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalid));
        liquidityHub.issue(invalid, user1, 1);
    }

    function test_cancelWithQueue_revertsForInvalidLcc_evenIfCallerIsIssuer() public {
        address invalid = makeAddr("invalidLcc");

        _store.target(address(liquidityHub)).sig("issuers(address,address)").with_key(invalid).with_key(factory)
            .checked_write(true);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalid));
        liquidityHub.cancelWithQueue(invalid, user1, 1, 1, user2);
    }

    function test_cancel_revertsForInvalidLcc_evenIfCallerIsIssuer() public {
        address invalid = makeAddr("invalidLcc_cancel");

        // Force onlyIssuer(invalid) to pass so onlyValidLcc becomes observable.
        _store.target(address(liquidityHub)).sig("issuers(address,address)").with_key(invalid).with_key(factory)
            .checked_write(true);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalid));
        liquidityHub.cancel(invalid, user1, 1);
    }

    function test_planCancelWithQueue_revertsForInvalidLcc_evenIfCallerIsIssuer() public {
        address invalid = makeAddr("invalidLcc");

        _store.target(address(liquidityHub)).sig("issuers(address,address)").with_key(invalid).with_key(factory)
            .checked_write(true);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalid));
        liquidityHub.planCancelWithQueue(invalid, factory, user1, 1, 1, user2);
    }

    function test_planCancel_revertsForInvalidLcc_evenIfCallerIsIssuer() public {
        address invalid = makeAddr("invalidLcc_planCancel");

        _store.target(address(liquidityHub)).sig("issuers(address,address)").with_key(invalid).with_key(factory)
            .checked_write(true);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalid));
        liquidityHub.planCancel(invalid, factory, user1, 1);
    }

    function test_unwrap_marketDerivedOnly_triggersPayPath() public {
        // Arrange: user1 has only market-derived balance.
        uint256 amount = 50;
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        // Provide underlying reserve so pay() can transfer out immediately.
        underlyingAsset1.mint(address(liquidityHub), amount);
        vm.prank(factory);
        liquidityHub.confirmTake(lccToken1, amount, false);

        // Make the market liquidity call succeed fully.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(amount));

        uint256 userUnderlyingBefore = underlyingAsset1.balanceOf(user1);

        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, amount);

        assertEq(underlyingAsset1.balanceOf(user1), userUnderlyingBefore + amount, "underlying should be paid");
    }

    function test_annulSettlementBeforeTransfer_usesLiquidBalanceAndQueueMath_whenLiquidBalanceExceedsQueued() public {
        // Create a settlement queue entry for user1.
        uint256 queued = 40;
        _createSettlementQueueEntry(lccToken1, user1, queued);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), queued);
        assertEq(liquidityHub.totalQueued(lccToken1), queued);

        // Call as the LCC (onlyValidLcc(_msgSender()) gate).
        // Pick balances where liquidBalance > queued and transfer amount bleeds into queue:
        // liquidBalance=100, queued=40 => transferableWithoutQueue=60; transfer=80 => bleed=20, annul=20.
        vm.prank(lccToken1);
        liquidityHub.annulSettlementBeforeTransfer(user1, 55, 45, 80);

        assertEq(liquidityHub.settleQueue(lccToken1, user1), queued - 20);
        assertEq(liquidityHub.totalQueued(lccToken1), queued - 20);
    }

    function test_annulSettlementBeforeTransfer_noAnnul_whenTransferDoesNotBleedIntoQueue() public {
        uint256 queued = 40;
        _createSettlementQueueEntry(lccToken1, user1, queued);

        // liquidBalance=100, queued=40 => transferableWithoutQueue=60; transfer=60 => no bleed.
        vm.prank(lccToken1);
        liquidityHub.annulSettlementBeforeTransfer(user1, 10, 90, 60);

        assertEq(liquidityHub.settleQueue(lccToken1, user1), queued);
        assertEq(liquidityHub.totalQueued(lccToken1), queued);
    }
}

