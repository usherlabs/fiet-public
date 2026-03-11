// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {OracleUtils} from "../src/libraries/OracleUtils.sol";

contract LiquidityCommitmentCertificateExposed is LiquidityCommitmentCertificate {
    constructor(
        address _underlyingAsset,
        string memory name,
        string memory symbol,
        uint8 __decimals,
        address _resilientOracleAddress,
        address _hub,
        address _factory
    )
        LiquidityCommitmentCertificate(
            _underlyingAsset, name, symbol, __decimals, _resilientOracleAddress, _hub, _factory
        )
    {}

    function exposed_isProtocolTransfer(address from, address to, bool fromProtocol, bool toProtocol)
        external
        pure
        returns (bool)
    {
        return _isProtocolTransfer(from, to, fromProtocol, toProtocol);
    }
}

/**
 * @title LiquidityCommitmentCertificateTest
 * @notice Unit tests for `src/LCC.sol` (LiquidityCommitmentCertificate).
 */
contract LiquidityCommitmentCertificateTest is Test {
    LiquidityCommitmentCertificate internal lcc;
    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificateExposed internal lccExposed;

    uint8 internal constant BOUND_NONE = 0;
    uint8 internal constant BOUND_ENDPOINT = 1;
    uint8 internal constant BOUND_EXEMPT = 2;

    mapping(address => mapping(address => uint8)) internal boundLevelMap;

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
    address internal factoryForThis = address(this);

    function setUp() public {
        // Mark a protocol-bound address for transfer tests.
        _setBoundLevel(protocol, BOUND_EXEMPT);

        // Deploy with hub == address(this) so we can observe callbacks.
        lcc =
            new LiquidityCommitmentCertificate(address(0xBEEF), "LCC", "LCC", 18, oracle, address(this), address(this));
        lccNative =
            new LiquidityCommitmentCertificate(address(0), "LCCN", "LCCN", 18, oracle, address(this), address(this));
        lccExposed = new LiquidityCommitmentCertificateExposed(
            address(0xBEEF), "LCCX", "LCCX", 18, oracle, address(this), address(this)
        );
    }

    // -------------------------
    // Minimal hub surface for LCC callbacks
    // -------------------------

    function lccToMarket(address) external view returns (bytes32, address) {
        return (marketIdForThis, factoryForThis);
    }

    function boundLevel(address factory, address who) external view returns (uint8) {
        return boundLevelMap[factory][who];
    }

    function boundLevels(address factory, address a, address b) external view returns (uint8, uint8) {
        return (boundLevelMap[factory][a], boundLevelMap[factory][b]);
    }

    function boundLevelOfLcc(address, address who) external view returns (uint8) {
        return boundLevelMap[factoryForThis][who];
    }

    function boundLevelsOfLcc(address, address a, address b) external view returns (uint8, uint8) {
        return (boundLevelMap[factoryForThis][a], boundLevelMap[factoryForThis][b]);
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

    function _setBoundLevel(address who, uint8 level) internal {
        boundLevelMap[factoryForThis][who] = level;
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

    function test_decimals_returnsConstructorValue() public {
        LiquidityCommitmentCertificate lcc6 = new LiquidityCommitmentCertificate(
            address(0xBEEF), "LCC6", "LCC6", 6, oracle, address(this), address(this)
        );
        assertEq(lcc6.decimals(), 6);
    }

    function recordWrappedIngress(address, uint256, uint256) external {}

    function test_mint_revertsWhenNotHub() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        lcc.mint(alice, 1, 0);
    }

    function test_mint_revertsWhenAmountIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        lcc.mint(alice, 0, 0);
    }

    function test_mint_updatesBucketsWhenNotIssued() public {
        lcc.mint(alice, 3, 5);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(lcc.balanceOf(alice), 8);
        assertEq(wrappedBal, 3);
        assertEq(marketBal, 5);
    }

    function test_mint_issuedTreatsAllAsWrappedViaBalancesOfFallback() public {
        lcc.mint(alice, 0, 7);

        // Issued mints must still populate buckets for non-exempt recipients.
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(lcc.balanceOf(alice), 7);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 7);
    }

    /// @dev Mutation-hardening: balancesOf() must fall back to `(fullBalance, 0)` even if the account is not exempt,
    ///      when buckets are empty but ERC20 balance is non-zero. This kills the `||` -> `&&` mutant.
    function test_balancesOf_bucketlessNonExempt_fallsBackToFullBalanceWrapped() public {
        address bucketless = makeAddr("bucketless");

        // Make the account exempt for mint so bucket maps remain empty.
        _setBoundLevel(bucketless, BOUND_EXEMPT);
        lcc.mint(bucketless, 0, 10);
        assertEq(lcc.balanceOf(bucketless), 10);

        // Now make it non-exempt while keeping bucket maps empty.
        _setBoundLevel(bucketless, BOUND_ENDPOINT);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(bucketless);
        assertEq(wrappedBal, 10);
        assertEq(marketBal, 0);
    }

    function test_burn_revertsWhenAmountIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        lcc.burn(alice, 0, 0);
    }

    function test_burn_revertsWhenNotHub() public {
        // Seed a burnable balance (hub mints).
        lcc.mint(alice, 5, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        lcc.burn(alice, 1, 0);
    }

    /// @dev Mutation-hardening: pairs a successful hub burn with an unauthorised burn attempt so
    ///      mutation runners attribute the access-control kill to burn() even under test selection.
    function test_burn_onlyHub_enforced() public {
        lcc.mint(alice, 5, 0);

        // Happy path: hub burns successfully.
        lcc.burn(alice, 1, 0);
        assertEq(lcc.balanceOf(alice), 4);

        // Unauthorised path: alice cannot burn.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        lcc.burn(alice, 1, 0);
    }

    function test_burn_nonProtocol_decrementsMarketDerivedBucket() public {
        lcc.mint(alice, 0, 10);
        (uint256 wrappedBalBefore, uint256 marketBalBefore) = lcc.balancesOf(alice);
        assertEq(wrappedBalBefore, 0);
        assertEq(marketBalBefore, 10);

        lcc.burn(alice, 0, 4);

        (uint256 wrappedBalAfter, uint256 marketBalAfter) = lcc.balancesOf(alice);
        assertEq(lcc.balanceOf(alice), 6);
        assertEq(wrappedBalAfter, 0);
        assertEq(marketBalAfter, 6);
    }

    function test_burn_protocolBoundSkipsBucketAccounting() public {
        // Give protocol address tokens without populating buckets (issued path).
        lcc.mint(protocol, 0, 10);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(protocol);
        assertEq(wrappedBal, 10);
        assertEq(marketBal, 0);

        // Non-issued burn should still skip buckets because protocol is bucket-exempt.
        lcc.burn(protocol, 0, 4);
        (wrappedBal, marketBal) = lcc.balancesOf(protocol);
        assertEq(lcc.balanceOf(protocol), 6);
        assertEq(wrappedBal, 6);
        assertEq(marketBal, 0);
    }

    function test_transfer_revertsForNonProtocolToNonProtocol() public {
        lcc.mint(alice, 5, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferNotAllowed.selector));
        lcc.transfer(bob, 1);
    }

    function test_isProtocolTransfer_allowsWhenEitherAddressIsZero() public view {
        assertTrue(lccExposed.exposed_isProtocolTransfer(address(0), alice, false, false));
        assertTrue(lccExposed.exposed_isProtocolTransfer(alice, address(0), false, false));
    }

    function test_transfer_protocolToNonProtocolAccruesMarketDerivedOnRecipient_andExecutesPlannedCancelHook() public {
        // Protocol-bound sender can transfer to non-protocol receiver.
        lcc.mint(protocol, 0, 5);

        vm.prank(protocol);
        lcc.transfer(alice, 3);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 3);

        // Annulment only occurs on non-protocol -> protocol transfers.
        assertEq(annulCalls, 0);

        assertEq(plannedCancelCalls, 1);
        assertEq(lastCancelSender, protocol);
        assertEq(lastCancelRecipient, alice);
    }

    function test_transfer_protocolToProtocol_doesNotAnnul_andBucketsRemainUntracked() public {
        address protocol2 = makeAddr("protocol2");
        _setBoundLevel(protocol2, BOUND_EXEMPT);

        // Give protocol address tokens without populating buckets (issued path).
        lcc.mint(protocol, 0, 9);

        vm.prank(protocol);
        lcc.transfer(protocol2, 4);

        // No annulment for protocol -> protocol.
        assertEq(annulCalls, 0);

        // Protocol recipients don't accumulate bucket maps; balancesOf reports ERC20 balance as wrapped via fallback.
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(protocol2);
        assertEq(lcc.balanceOf(protocol2), 4);
        assertEq(wrappedBal, 4);
        assertEq(marketBal, 0);

        assertEq(plannedCancelCalls, 1);
        assertEq(lastCancelSender, protocol);
        assertEq(lastCancelRecipient, protocol2);
    }

    function test_transfer_nonProtocolToProtocol_doesNotRevert_whenIssuedMintPopulatesBuckets() public {
        // Make sure recipient is protocol-bound; sender is not.
        assertEq(boundLevelMap[factoryForThis][protocol], BOUND_EXEMPT);
        assertEq(boundLevelMap[factoryForThis][alice], BOUND_NONE);

        // Issued mint to a non-exempt recipient should still create bucket state.
        lcc.mint(alice, 7, 0);
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(alice);
        assertEq(wrappedBal, 7);
        assertEq(marketBal, 0);

        // Non-protocol -> protocol transfer should succeed (transfers are allowed when either side is protocol-bound).
        vm.prank(alice);
        lcc.transfer(protocol, 1);

        assertEq(lcc.balanceOf(protocol), 1);
    }

    function test_transfer_nonProtocolToProtocolAnnulsSettlementAndConsumesMarketFirstThenWrapped_andExecutesPlannedCancel()
        public
    {
        // Target is protocol-bound.
        _setBoundLevel(address(this), BOUND_EXEMPT);

        // Alice has mixed buckets.
        lcc.mint(alice, 4, 6);
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

    function test_transfer_nonProtocolToBucketTrackedEndpoint_preservesSplit() public {
        address mmpm = makeAddr("mmpm");
        _setBoundLevel(mmpm, BOUND_ENDPOINT);

        lcc.mint(alice, 20, 80);

        vm.prank(alice);
        lcc.transfer(mmpm, 100);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(mmpm);
        assertEq(wrappedBal, 20);
        assertEq(marketBal, 80);
    }

    /// @notice Regression: non-protocol -> bucket-tracked endpoint must preserve market-derived balance (not trigger fallback).
    function test_transfer_nonProtocolToBucketTrackedEndpoint_marketDerivedOnly_staysMarketDerived() public {
        address mmpm = makeAddr("mmpm");
        _setBoundLevel(mmpm, BOUND_ENDPOINT);

        lcc.mint(alice, 0, 100);

        vm.prank(alice);
        lcc.transfer(mmpm, 100);

        assertEq(lcc.balanceOf(mmpm), 100);
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(mmpm);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 100);
        assertEq(wrappedBal + marketBal, lcc.balanceOf(mmpm), "bucket sum must match ERC20 balance for endpoint");
    }

    function test_transfer_bucketTrackedEndpointToNonProtocol_carriesSplit() public {
        address mmpm = makeAddr("mmpm");
        _setBoundLevel(mmpm, BOUND_ENDPOINT);

        lcc.mint(alice, 20, 80);
        vm.prank(alice);
        lcc.transfer(mmpm, 100);

        vm.prank(mmpm);
        lcc.transfer(bob, 50);

        (uint256 wrappedBalBob, uint256 marketBalBob) = lcc.balancesOf(bob);
        assertEq(wrappedBalBob, 0);
        assertEq(marketBalBob, 50);

        (uint256 wrappedBalMmpm, uint256 marketBalMmpm) = lcc.balancesOf(mmpm);
        assertEq(wrappedBalMmpm, 20);
        assertEq(marketBalMmpm, 30);
    }

    function test_transfer_bucketExemptEndpointToBucketTrackedEndpoint_creditsMarketDerivedOnly() public {
        address mmpm = makeAddr("mmpm");
        _setBoundLevel(mmpm, BOUND_ENDPOINT);

        lcc.mint(protocol, 0, 12);

        vm.prank(protocol);
        lcc.transfer(mmpm, 7);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(mmpm);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 7);

        assertEq(annulCalls, 0);
        assertEq(plannedCancelCalls, 1);
        assertEq(lastCancelSender, protocol);
        assertEq(lastCancelRecipient, mmpm);
    }

    function test_transfer_bucketTrackedEndpointToBucketExemptEndpoint_doesNotCreditRecipientBuckets() public {
        address mmpm = makeAddr("mmpm");
        _setBoundLevel(mmpm, BOUND_ENDPOINT);

        lcc.mint(alice, 20, 80);
        vm.prank(alice);
        lcc.transfer(mmpm, 100);

        vm.prank(mmpm);
        lcc.transfer(protocol, 60);

        assertEq(lcc.balanceOf(protocol), 60);
        (uint256 wrappedBalProtocol, uint256 marketBalProtocol) = lcc.balancesOf(protocol);
        assertEq(wrappedBalProtocol, 60);
        assertEq(marketBalProtocol, 0);

        (uint256 wrappedBalMmpm, uint256 marketBalMmpm) = lcc.balancesOf(mmpm);
        assertEq(wrappedBalMmpm, 20);
        assertEq(marketBalMmpm, 20);
    }

    function test_transfer_nonProtocolToProtocol_consumesMarketThenWrapped_partial() public {
        lcc.mint(alice, 4, 6);

        // Transfer 8 to protocol (consumes 6 market + 2 wrapped).
        vm.prank(alice);
        lcc.transfer(protocol, 8);

        (uint256 wrappedBalAfter, uint256 marketBalAfter) = lcc.balancesOf(alice);
        assertEq(wrappedBalAfter, 2);
        assertEq(marketBalAfter, 0);
    }

    function test_transfer_nonProtocolToProtocol_whenMarketCoversAmount_doesNotConsumeWrapped() public {
        // Alice has both buckets, but market-derived fully covers the transfer amount.
        lcc.mint(alice, 5, 10);
        (uint256 wrappedBalBefore, uint256 marketBalBefore) = lcc.balancesOf(alice);
        assertEq(wrappedBalBefore, 5);
        assertEq(marketBalBefore, 10);

        vm.prank(alice);
        lcc.transfer(protocol, 8);

        // Market-derived decreases by exactly amount; wrapped must remain unchanged (remaining == 0 path).
        (uint256 wrappedBalAfter, uint256 marketBalAfter) = lcc.balancesOf(alice);
        assertEq(wrappedBalAfter, 5);
        assertEq(marketBalAfter, 2);

        // Annulment should have been called with pre-transfer bucket values and the transfer amount.
        assertEq(annulCalls, 1);
        assertEq(lastAnnulFrom, alice);
        assertEq(lastAnnulWrapped, 5);
        assertEq(lastAnnulMarket, 10);
        assertEq(lastAnnulAmount, 8);

        assertEq(plannedCancelCalls, 1);
        assertEq(lastCancelSender, alice);
        assertEq(lastCancelRecipient, protocol);
    }

    /// @dev Mutation-hardening: bucket-tracked protocol -> protocol transfer must:
    ///      - not revert on correct total balance arithmetic (kills `+` -> `-` mutant)
    ///      - debit sender buckets (kills `-=` -> `+=` mutants)
    ///      - credit recipient buckets (kills `+=` -> `-=` and gating mutants)
    function test_transfer_bucketTrackedProtocolToBucketTrackedProtocol_debitsAndCreditsBuckets() public {
        address from = makeAddr("fromEndpoint");
        address to = makeAddr("toEndpoint");
        _setBoundLevel(from, BOUND_ENDPOINT);
        _setBoundLevel(to, BOUND_ENDPOINT);

        // Give `from` a mixed bucket split by transferring from a non-protocol holder.
        lcc.mint(alice, 40, 60);
        vm.prank(alice);
        lcc.transfer(from, 100);

        (uint256 fromWrappedBefore, uint256 fromMarketBefore) = lcc.balancesOf(from);
        assertEq(fromWrappedBefore, 40);
        assertEq(fromMarketBefore, 60);

        vm.prank(from);
        lcc.transfer(to, 70); // consumes 60 market + 10 wrapped

        (uint256 fromWrappedAfter, uint256 fromMarketAfter) = lcc.balancesOf(from);
        assertEq(fromWrappedAfter, 30);
        assertEq(fromMarketAfter, 0);

        (uint256 toWrapped, uint256 toMarket) = lcc.balancesOf(to);
        assertEq(toWrapped, 10);
        assertEq(toMarket, 60);
        assertEq(toWrapped + toMarket, lcc.balanceOf(to));
    }

    /// @dev Mutation-hardening: bucket-tracked protocol -> bucket-exempt protocol must NOT credit bucket maps
    ///      while exempt. We flip the recipient to non-exempt afterwards to make bucket pollution observable.
    function test_transfer_bucketTrackedEndpointToBucketExemptEndpoint_doesNotCreditBucketsWhileExempt_evenAfterFlip()
        public
    {
        address mmpm = makeAddr("mmpmFlip");
        _setBoundLevel(mmpm, BOUND_ENDPOINT);

        // protocol is bound + exempt by default in setUp().
        assertEq(boundLevelMap[factoryForThis][protocol], BOUND_EXEMPT);

        // Seed mmpm with mixed buckets.
        lcc.mint(alice, 40, 60);
        vm.prank(alice);
        lcc.transfer(mmpm, 100);

        // Transfer to exempt protocol.
        vm.prank(mmpm);
        lcc.transfer(protocol, 70);

        // Flip recipient to non-exempt; if any buckets were incorrectly credited while exempt,
        // balancesOf will return the bucket split rather than `(fullBalance, 0)`.
        _setBoundLevel(protocol, BOUND_ENDPOINT);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(protocol);
        assertEq(wrappedBal, 70);
        assertEq(marketBal, 0);
    }
}

