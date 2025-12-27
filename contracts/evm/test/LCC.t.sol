// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {OracleUtils} from "../src/libraries/OracleUtils.sol";

contract MockMarketFactoryBounds {
    mapping(address => bool) public bounds;

    function setBounds(address who, bool isBound) external {
        bounds[who] = isBound;
    }
}

/**
 * @title LiquidityCommitmentCertificateTest
 * @notice Unit tests for `src/LCC.sol` (LiquidityCommitmentCertificate).
 */
contract LiquidityCommitmentCertificateTest is Test {
    MockMarketFactoryBounds internal marketFactory;

    LiquidityCommitmentCertificate internal lcc;
    LiquidityCommitmentCertificate internal lccNative;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal protocol = makeAddr("protocol");
    address internal oracle = makeAddr("ResilientOracle");

    // Records for hub callbacks
    uint256 internal plannedCancelCalls;
    address internal lastCancelSender;
    address internal lastCancelRecipient;

    uint256 internal annulCalls;
    address internal lastAnnulFrom;
    uint256 internal lastAnnulWrapped;
    uint256 internal lastAnnulMarket;
    uint256 internal lastAnnulAmount;

    bytes32 internal marketIdForThis = bytes32("market-id");
    address internal factoryForThis = makeAddr("factory");

    function setUp() public {
        marketFactory = new MockMarketFactoryBounds();

        // Mark a protocol-bound address for transfer tests.
        marketFactory.setBounds(protocol, true);

        // Deploy with hub == address(this) so we can observe callbacks.
        lcc = new LiquidityCommitmentCertificate(address(marketFactory), address(0xBEEF), "LCC", "LCC", 18, oracle);
        lccNative = new LiquidityCommitmentCertificate(address(marketFactory), address(0), "LCCN", "LCCN", 18, oracle);
    }

    // -------------------------
    // Minimal hub surface for LCC callbacks
    // -------------------------

    function lccToMarket(address) external view returns (bytes32, address) {
        return (marketIdForThis, factoryForThis);
    }

    function executePlannedCancel(address sender, address cancelFromRecipient) external {
        plannedCancelCalls++;
        lastCancelSender = sender;
        lastCancelRecipient = cancelFromRecipient;
    }

    function annulSettlementBeforeTransfer(
        address from,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance,
        uint256 amountToTransfer
    ) external {
        annulCalls++;
        lastAnnulFrom = from;
        lastAnnulWrapped = wrappedBalance;
        lastAnnulMarket = marketDerivedBalance;
        lastAnnulAmount = amountToTransfer;
    }

    // -------------------------
    // Tests
    // -------------------------

    function test_marketId_readsFromHub() public view {
        assertEq(lcc.marketId(), marketIdForThis);
    }

    function test_underlying_returnsNativeOracleAddrWhenCallerIsOracleAndUnderlyingIsZero() public {
        assertEq(lccNative.underlying(), address(0));

        vm.prank(oracle);
        assertEq(lccNative.underlying(), OracleUtils.RESILIENT_ORACLE_NATIVE_TOKEN_ADDR);
    }

    function test_mint_revertsWhenNotHub() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        lcc.mint(alice, 1, 0, false);
    }

    function test_mint_revertsWhenAmountIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        lcc.mint(alice, 0, 0, false);
    }

    function test_mint_updatesBucketsWhenNotIssued() public {
        lcc.mint(alice, 3, 5, false);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(lcc.balanceOf(alice), 8);
        assertEq(wrappedBal, 3);
        assertEq(marketBal, 5);
    }

    function test_mint_issuedTreatsAllAsWrappedViaBalancesOfFallback() public {
        lcc.mint(alice, 0, 7, true);

        // issued=true skips bucket updates; balancesOf should treat ERC20 balance as wrapped.
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(lcc.balanceOf(alice), 7);
        assertEq(wrappedBal, 7);
        assertEq(marketBal, 0);
    }

    function test_burn_revertsWhenAmountIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        lcc.burn(alice, 0, 0, false);
    }

    function test_burn_protocolBoundSkipsBucketAccounting() public {
        // Give protocol address tokens without populating buckets (issued path).
        lcc.mint(protocol, 0, 10, true);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(protocol);
        assertEq(wrappedBal, 10);
        assertEq(marketBal, 0);

        // Non-issued burn should still skip buckets because marketFactory.bounds(protocol) == true.
        lcc.burn(protocol, 0, 4, false);
        (wrappedBal, marketBal) = lcc.balancesOf(protocol);
        assertEq(lcc.balanceOf(protocol), 6);
        assertEq(wrappedBal, 6);
        assertEq(marketBal, 0);
    }

    function test_transfer_revertsForNonProtocolToNonProtocol() public {
        lcc.mint(alice, 5, 0, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferNotAllowed.selector));
        lcc.transfer(bob, 1);
    }

    function test_transfer_protocolToNonProtocolAccruesMarketDerivedOnRecipient_andExecutesPlannedCancelHook() public {
        // Protocol-bound sender can transfer to non-protocol receiver.
        lcc.mint(protocol, 0, 5, true);

        vm.prank(protocol);
        lcc.transfer(alice, 3);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 3);

        assertEq(plannedCancelCalls, 1);
        assertEq(lastCancelSender, protocol);
        assertEq(lastCancelRecipient, alice);
    }

    function test_transfer_nonProtocolToProtocolAnnulsSettlementAndConsumesMarketFirstThenWrapped_andExecutesPlannedCancel()
        public
    {
        // Target is protocol-bound.
        marketFactory.setBounds(address(this), true);

        // Alice has mixed buckets.
        lcc.mint(alice, 4, 6, false);
        (uint256 wrappedBalBefore, uint256 marketBalBefore) = lcc.balancesOf(alice);
        assertEq(wrappedBalBefore, 4);
        assertEq(marketBalBefore, 6);

        // Transfer 8 to protocol (consumes 6 market + 2 wrapped).
        vm.prank(alice);
        lcc.transfer(address(this), 8);

        (uint256 wrappedBalAfter, uint256 marketBalAfter) = lcc.balancesOf(alice);
        assertEq(wrappedBalAfter, 2);
        assertEq(marketBalAfter, 0);

        assertEq(annulCalls, 1);
        assertEq(lastAnnulFrom, alice);
        assertEq(lastAnnulWrapped, 4);
        assertEq(lastAnnulMarket, 6);
        assertEq(lastAnnulAmount, 8);

        assertEq(plannedCancelCalls, 1);
        assertEq(lastCancelSender, alice);
        assertEq(lastCancelRecipient, address(this));
    }
}

