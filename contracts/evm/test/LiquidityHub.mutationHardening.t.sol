// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice Mutation hardening tests for LiquidityHub.
 * @dev Focused assertions to kill surviving mutants without pulling in full integration harnesses.
 */
contract LiquidityHubMutationHardeningTest is LiquidityHubTestBase {
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

